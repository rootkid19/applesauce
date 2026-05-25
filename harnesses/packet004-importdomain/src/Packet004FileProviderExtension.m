#import <Foundation/Foundation.h>
#import <FileProvider/FileProvider.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSProgress *Packet004CompletedProgress(void) {
    NSProgress *progress = [NSProgress progressWithTotalUnitCount:1];
    progress.completedUnitCount = 1;
    return progress;
}

static NSError *Packet004NoSuchItemError(NSFileProviderItemIdentifier identifier) {
    return [NSError errorWithDomain:NSFileProviderErrorDomain
                               code:NSFileProviderErrorNoSuchItem
                           userInfo:@{NSFileProviderErrorNonExistentItemIdentifierKey: identifier ?: @"(null)"}];
}

@interface Packet004Item : NSObject <NSFileProviderItem>
@property(nonatomic, readonly, copy) NSFileProviderItemIdentifier itemIdentifier;
@property(nonatomic, readonly, copy) NSFileProviderItemIdentifier parentItemIdentifier;
@property(nonatomic, readonly, copy) NSString *filename;
@property(nonatomic, readonly, copy) UTType *contentType;
@property(nonatomic, readonly) NSFileProviderItemCapabilities capabilities;
- (instancetype)initWithIdentifier:(NSFileProviderItemIdentifier)identifier parent:(NSFileProviderItemIdentifier)parent filename:(NSString *)filename contentType:(UTType *)contentType;
@end

@implementation Packet004Item

- (instancetype)initWithIdentifier:(NSFileProviderItemIdentifier)identifier parent:(NSFileProviderItemIdentifier)parent filename:(NSString *)filename contentType:(UTType *)contentType {
    self = [super init];
    if (self) {
        _itemIdentifier = [identifier copy];
        _parentItemIdentifier = [parent copy];
        _filename = [filename copy];
        _contentType = [contentType copy];
        _capabilities = NSFileProviderItemCapabilitiesAllowsReading |
                        NSFileProviderItemCapabilitiesAllowsWriting |
                        NSFileProviderItemCapabilitiesAllowsAddingSubItems |
                        NSFileProviderItemCapabilitiesAllowsDeleting |
                        NSFileProviderItemCapabilitiesAllowsRenaming;
    }
    return self;
}

@end

@interface Packet004EmptyEnumerator : NSObject <NSFileProviderEnumerator>
@end

@implementation Packet004EmptyEnumerator

- (void)invalidate {
}

- (void)enumerateItemsForObserver:(id<NSFileProviderEnumerationObserver>)observer startingAtPage:(NSFileProviderPage)page {
    (void)page;
    [observer didEnumerateItems:@[]];
    [observer finishEnumeratingUpToPage:nil];
}

- (void)enumerateChangesForObserver:(id<NSFileProviderChangeObserver>)observer fromSyncAnchor:(NSFileProviderSyncAnchor)syncAnchor {
    (void)syncAnchor;
    [observer finishEnumeratingChangesUpToSyncAnchor:[@"packet004-anchor" dataUsingEncoding:NSUTF8StringEncoding] moreComing:NO];
}

- (void)currentSyncAnchorWithCompletionHandler:(void (^)(NSFileProviderSyncAnchor _Nullable))completionHandler {
    completionHandler([@"packet004-anchor" dataUsingEncoding:NSUTF8StringEncoding]);
}

@end

@interface Packet004FileProviderExtension : NSObject <NSFileProviderReplicatedExtension>
@property(nonatomic, readonly, strong) NSFileProviderDomain *domain;
@end

@implementation Packet004FileProviderExtension

- (instancetype)initWithDomain:(NSFileProviderDomain *)domain {
    self = [super init];
    if (self) {
        _domain = domain;
    }
    return self;
}

- (void)invalidate {
}

- (id<NSFileProviderItem>)rootItem {
    return [[Packet004Item alloc] initWithIdentifier:NSFileProviderRootContainerItemIdentifier
                                             parent:NSFileProviderRootContainerItemIdentifier
                                           filename:self.domain.displayName ?: @"Packet004"
                                        contentType:UTTypeFolder];
}

- (nullable id<NSFileProviderEnumerator>)enumeratorForContainerItemIdentifier:(NSFileProviderItemIdentifier)containerItemIdentifier
                                                                      request:(NSFileProviderRequest *)request
                                                                        error:(NSError **)error {
    (void)request;
    if ([containerItemIdentifier isEqualToString:NSFileProviderRootContainerItemIdentifier] ||
        [containerItemIdentifier isEqualToString:NSFileProviderWorkingSetContainerItemIdentifier]) {
        return [Packet004EmptyEnumerator new];
    }

    if (error) {
        *error = Packet004NoSuchItemError(containerItemIdentifier);
    }
    return nil;
}

- (NSProgress *)itemForIdentifier:(NSFileProviderItemIdentifier)identifier
                          request:(NSFileProviderRequest *)request
                completionHandler:(void (^)(id<NSFileProviderItem> _Nullable, NSError * _Nullable))completionHandler {
    (void)request;
    if ([identifier isEqualToString:NSFileProviderRootContainerItemIdentifier]) {
        completionHandler([self rootItem], nil);
    } else {
        completionHandler(nil, Packet004NoSuchItemError(identifier));
    }
    return Packet004CompletedProgress();
}

- (NSProgress *)fetchContentsForItemWithIdentifier:(NSFileProviderItemIdentifier)itemIdentifier
                                           version:(NSFileProviderItemVersion *)requestedVersion
                                           request:(NSFileProviderRequest *)request
                                 completionHandler:(void (^)(NSURL * _Nullable, id<NSFileProviderItem> _Nullable, NSError * _Nullable))completionHandler {
    (void)requestedVersion;
    (void)request;
    completionHandler(nil, nil, Packet004NoSuchItemError(itemIdentifier));
    return Packet004CompletedProgress();
}

- (NSProgress *)createItemBasedOnTemplate:(id<NSFileProviderItem>)itemTemplate
                                   fields:(NSFileProviderItemFields)fields
                                 contents:(NSURL *)url
                                  options:(NSFileProviderCreateItemOptions)options
                                  request:(NSFileProviderRequest *)request
                        completionHandler:(void (^)(id<NSFileProviderItem> _Nullable, NSFileProviderItemFields, BOOL, NSError * _Nullable))completionHandler {
    (void)fields;
    (void)url;
    (void)options;
    (void)request;
    completionHandler(itemTemplate, 0, NO, nil);
    return Packet004CompletedProgress();
}

- (NSProgress *)modifyItem:(id<NSFileProviderItem>)item
               baseVersion:(NSFileProviderItemVersion *)version
             changedFields:(NSFileProviderItemFields)changedFields
                  contents:(NSURL *)newContents
                   options:(NSFileProviderModifyItemOptions)options
                   request:(NSFileProviderRequest *)request
         completionHandler:(void (^)(id<NSFileProviderItem> _Nullable, NSFileProviderItemFields, BOOL, NSError * _Nullable))completionHandler {
    (void)version;
    (void)changedFields;
    (void)newContents;
    (void)options;
    (void)request;
    completionHandler(item, 0, NO, nil);
    return Packet004CompletedProgress();
}

- (NSProgress *)deleteItemWithIdentifier:(NSFileProviderItemIdentifier)identifier
                             baseVersion:(NSFileProviderItemVersion *)version
                                 options:(NSFileProviderDeleteItemOptions)options
                                 request:(NSFileProviderRequest *)request
                       completionHandler:(void (^)(NSError * _Nullable))completionHandler {
    (void)identifier;
    (void)version;
    (void)options;
    (void)request;
    completionHandler(nil);
    return Packet004CompletedProgress();
}

- (void)importDidFinishWithCompletionHandler:(void (^)(void))completionHandler {
    completionHandler();
}

@end

extern int NSExtensionMain(int argc, char **argv);

int main(int argc, char **argv) {
    @autoreleasepool {
        return NSExtensionMain(argc, argv);
    }
}
