//
//  ETSSynchronization.m
//  ETSMobile
//
//  Created by Jean-Philippe Martin on 2014-03-21.
//  Copyright (c) 2014 ApplETS. All rights reserved.
//

#import "ETSSynchronization.h"
#import "ETSAppDelegate.h"
#import "NSManagedObject+SetValues.h"

@interface ETSSynchronization ()

+ (NSManagedObjectContext *)mainManagedObjectContext;
+ (NSDictionary *)mappings;
- (void)synchronizeJSONArray:(NSArray *)jsonObjects error:(NSError * __autoreleasing *)error;
- (void)synchronizeJSONDictionary:(NSDictionary *)jsonDictionary error:(NSError * __autoreleasing *)error;
- (void)deleteExpiredObjects:(NSArray *)objects forEntity:(NSString *)entity key:(NSString *)key managedObjectContext:(NSManagedObjectContext *)managedObjectContext;
- (void)addControllerContextDidSave:(NSNotification*)saveNotification;

@property (nonatomic, strong) NSManagedObjectContext *managedObjectContext;

@end


@implementation ETSSynchronization

+ (NSManagedObjectContext *)mainManagedObjectContext
{
    return [(ETSAppDelegate *)[[UIApplication sharedApplication] delegate] managedObjectContext];
}

+ (NSDictionary *)mappings
{
    return [[NSDictionary alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"ETSAPICoreDataMapping" ofType:@"plist"]];
}

- (id)init
{
    self = [super init];
    if (self) {
        self.saveAutomatically = YES;
        self.managedObjectContext = nil;
        self.ignoredAttributes = nil;
    }
    return self;
}

- (void)deleteExpiredObjects:(NSArray *)objects forEntity:(NSString *)entity key:(NSString *)key managedObjectContext:(NSManagedObjectContext *)managedObjectContext
{
    NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:entity];
    NSArray *objectsKeys = [objects valueForKey:[ETSSynchronization mappings][entity][key]];
    
    request.predicate = [NSPredicate predicateWithFormat:@"NOT (%K IN %@)", key, objectsKeys];
    request.includesPropertyValues = NO;
    NSError *error = nil;
    NSArray *expiratedObjects = [managedObjectContext executeFetchRequest:request error:&error];
    
    for (NSManagedObject *object in expiratedObjects) {
        [managedObjectContext deleteObject:object];
    }
}

- (void)synchronize:(NSError * __autoreleasing *)error
{
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
    __weak typeof(self) bself = self;
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:self.request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error)
    {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
        });
        
        //NSLog(@"%@", [NSString stringWithUTF8String:[data bytes]]);
        
        // FIXME: traiter si data est vide ou s'il y a erreur
        if (!data) return;
        
        NSError *jsonError = nil;
        NSDictionary *jsonObjects = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:&jsonError];
        
        if ([bself.delegate respondsToSelector:@selector(synchronization:didReceiveDictionary:)]) [bself.delegate synchronization:bself didReceiveDictionary:jsonObjects];

        if ([bself.delegate respondsToSelector:@selector(synchronization:validateJSONResponse:)]) {
            
            ETSSynchronizationResponse validationResponse = [bself.delegate synchronization:bself validateJSONResponse:jsonObjects];
            
            dispatch_sync(dispatch_get_main_queue(), ^{
                if (validationResponse == ETSSynchronizationResponseAuthenticationError || validationResponse == ETSSynchronizationResponseUnknownError)
                {
                    if ([bself.delegate respondsToSelector:@selector(synchronization:didReceiveResponse:)])
                        [bself.delegate synchronization:bself didReceiveResponse:validationResponse];
                    
                    if ([bself.delegate respondsToSelector:@selector(synchronizationDidFinishLoading:)])
                        [bself.delegate synchronizationDidFinishLoading:bself];
                    
                    return;
                }
                else if (validationResponse == ETSSynchronizationResponseValid)
                {
                    if ([bself.delegate respondsToSelector:@selector(synchronization:didReceiveResponse:)])
                        [bself.delegate synchronization:bself didReceiveResponse:ETSSynchronizationResponseValid];
                }
            });
        }
        
        bself.managedObjectContext = [[NSManagedObjectContext alloc] init];
        bself.managedObjectContext.undoManager = nil;
        bself.managedObjectContext.persistentStoreCoordinator = [[ETSSynchronization mainManagedObjectContext] persistentStoreCoordinator];
        [[NSNotificationCenter defaultCenter] addObserver:bself selector:@selector(addControllerContextDidSave:) name:NSManagedObjectContextDidSaveNotification object:bself.managedObjectContext];
        
        if (!bself.dateFormatter) bself.dateFormatter = [[NSDateFormatter alloc] init];

        __block id json = [jsonObjects valueForKeyPath:bself.objectsKeyPath];
        
        if ([bself.delegate respondsToSelector:@selector(synchronization:updateJSONObjects:)]) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                json = [bself.delegate synchronization:bself updateJSONObjects:json];
            });
        }
        
        NSError *syncError;

        if ([json isKindOfClass:[NSArray class]])           [bself synchronizeJSONArray:json error:&syncError];
        else if ([json isKindOfClass:[NSDictionary class]]) [bself synchronizeJSONDictionary:json error:&syncError];

        if (bself.saveAutomatically) {
            NSError *error;
            if (![bself.managedObjectContext save:&error]) {
                // FIXME: Update to handle the error appropriately.
                NSLog(@"Unresolved error %@, %@", error, [error userInfo]);
            }
        }
        if ([bself.delegate respondsToSelector:@selector(synchronizationDidFinishLoading:)]) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [bself.delegate synchronizationDidFinishLoading:bself];
            });
        }

    }];
    
    [task resume];
}

- (void)synchronizeJSONArray:(NSArray *)jsonObjects error:(NSError * __autoreleasing *)error
{
    // Suppression des objets présents sur la base de données mais non sur la réponse de l'API.
    [self deleteExpiredObjects:jsonObjects forEntity:self.entityName key:self.compareKey managedObjectContext:self.managedObjectContext];
    
    // Ajout et mise à jour des autres objets de la réponse de l'API.
    NSSortDescriptor *descriptor = [[NSSortDescriptor alloc] initWithKey:[[ETSSynchronization mappings][self.entityName] valueForKey:self.compareKey] ascending:YES];
    jsonObjects = [jsonObjects sortedArrayUsingDescriptors:@[descriptor]];
    
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:self.entityName];
    
    if (self.predicate) [fetchRequest setPredicate:self.predicate];
    
    NSArray *sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:self.compareKey ascending:YES]];
    [fetchRequest setSortDescriptors:sortDescriptors];
    
    NSError *fetchError;
    NSMutableArray *coredataArray = [NSMutableArray arrayWithArray:[self.managedObjectContext executeFetchRequest:fetchRequest error:&fetchError]];
    
    NSUInteger i = 0;
    for (NSDictionary *lObject in jsonObjects)
    {
        NSManagedObject * rObject = nil;
        if (i < [coredataArray count]) rObject = coredataArray[i];
        
        id leftOperand = lObject[[ETSSynchronization mappings][self.entityName][self.compareKey]];
        id rightOperand = [rObject valueForKey:self.compareKey];
        
        NSComparisonResult comparisonResult;
        if ([rightOperand isKindOfClass:[NSNumber class]]) {
            comparisonResult = [leftOperand compare:rightOperand];
        }
        else if ([rightOperand isKindOfClass:[NSString class]]) {
            comparisonResult = [leftOperand caseInsensitiveCompare:rightOperand];
        }
        
        if (!rObject || comparisonResult == NSOrderedAscending) {
            NSManagedObject *managedObject = [NSEntityDescription insertNewObjectForEntityForName:self.entityName inManagedObjectContext:self.managedObjectContext];
            [managedObject safeSetValuesForKeysWithDictionary:lObject dateFormatter:self.dateFormatter mapping:[ETSSynchronization mappings][self.entityName]];
            if ([self.delegate respondsToSelector:@selector(synchronization:didReceiveObject:forManagedObject:)]) [self.delegate synchronization:self didReceiveObject:lObject forManagedObject:managedObject];
        }
        
        else if (comparisonResult == NSOrderedSame) {
            NSDictionary *attributes = [[rObject entity] attributesByName];
            for (NSString *attribute in attributes) {
                if ([self.ignoredAttributes count] > 0 &&
                    [[self.ignoredAttributes filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self == %@", attribute]] count] > 0) {
                    continue;
                }
                [rObject setValue:nil forKey:attribute];
            }
            [rObject safeSetValuesForKeysWithDictionary:lObject dateFormatter:self.dateFormatter mapping:[ETSSynchronization mappings][self.entityName]];
            if ([self.delegate respondsToSelector:@selector(synchronization:didReceiveObject:forManagedObject:)])
                [self.delegate synchronization:self didReceiveObject:lObject forManagedObject:rObject];
            i++;
        }
    }

}

- (void)synchronizeJSONDictionary:(NSDictionary *)jsonDictionary error:(NSError * __autoreleasing *)error
{
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
    NSEntityDescription *entity = [NSEntityDescription entityForName:self.entityName inManagedObjectContext:self.managedObjectContext];
    [fetchRequest setEntity:entity];
    
    if (self.predicate) [fetchRequest setPredicate:self.predicate];

    [fetchRequest setSortDescriptors:@[[[NSSortDescriptor alloc] initWithKey:self.compareKey ascending:YES]]];
    
    NSError *fetchError;
    NSArray *coredataArray = [self.managedObjectContext executeFetchRequest:fetchRequest error:&fetchError];
    
    if ([coredataArray count] > 0) {
        NSManagedObject *coreObject = coredataArray[0];
        NSDictionary *attributes = [[coreObject entity] attributesByName];
        for (NSString *attribute in attributes) {
            if ([self.ignoredAttributes count] > 0 &&
                [[self.ignoredAttributes filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self == %@", attribute]] count] > 0) {
                continue;
            }
            [coreObject setValue:nil forKey:attribute];
        }
        [coreObject safeSetValuesForKeysWithDictionary:jsonDictionary dateFormatter:self.dateFormatter mapping:[ETSSynchronization mappings][self.entityName]];
        if ([self.delegate respondsToSelector:@selector(synchronization:didReceiveObject:forManagedObject:)])
            [self.delegate synchronization:self didReceiveObject:jsonDictionary forManagedObject:coreObject];
    }
    
    else {
        NSManagedObject *managedObject = [NSEntityDescription insertNewObjectForEntityForName:self.entityName inManagedObjectContext:self.managedObjectContext];
        [managedObject safeSetValuesForKeysWithDictionary:jsonDictionary dateFormatter:self.dateFormatter mapping:[ETSSynchronization mappings][self.entityName]];
        if ([self.delegate respondsToSelector:@selector(synchronization:didReceiveObject:forManagedObject:)]) [self.delegate synchronization:self didReceiveObject:jsonDictionary forManagedObject:managedObject];
    }
}

- (void)addControllerContextDidSave:(NSNotification*)saveNotification
{
    [[ETSSynchronization mainManagedObjectContext] performSelectorOnMainThread:@selector(mergeChangesFromContextDidSaveNotification:) withObject:saveNotification waitUntilDone:YES];
}

- (void)saveManagedObjectContext
{
    if (self.managedObjectContext) {
        NSError *error;
        if (![self.managedObjectContext save:&error]) {
            // FIXME: Update to handle the error appropriately.
            NSLog(@"Unresolved error %@, %@", error, [error userInfo]);
        }
    
        [[NSNotificationCenter defaultCenter] removeObserver:self name:NSManagedObjectContextDidSaveNotification object:self.managedObjectContext];
        self.managedObjectContext = nil;
    }
}

@end
