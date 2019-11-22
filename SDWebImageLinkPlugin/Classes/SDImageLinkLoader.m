/*
* This file is part of the SDWebImage package.
* (c) Olivier Poitrey <rs@dailymotion.com>
*
* For the full copyright and license information, please view the LICENSE
* file that was distributed with this source code.
*/

#import "SDImageLinkLoader.h"
#import "SDWebImageLinkDefine.h"
#import "SDWebImageLinkError.h"
#import "NSImage+SDWebImageLinkPlugin.h"
#import <LinkPresentation/LinkPresentation.h>
#if SD_UIKIT
#import <MobileCoreServices/MobileCoreServices.h>
#endif

@interface LPMetadataProvider (SDWebImageOperation) <SDWebImageOperation>

@end

@interface SDImageLinkLoaderContext : NSObject

@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) SDImageLoaderProgressBlock progressBlock;

@end

@implementation SDImageLinkLoaderContext
@end

@interface SDImageLinkLoader ()

@end

@implementation SDImageLinkLoader

- (instancetype)init {
    self = [super init];
    if (self) {
        
    }
    return self;
}

+ (SDImageLinkLoader *)sharedLoader {
    static SDImageLinkLoader *loader;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        loader = [[SDImageLinkLoader alloc] init];
    });
    return loader;
}

#pragma mark - SDImageLoader

- (BOOL)canRequestImageForURL:(NSURL *)url {
    return YES;
}

- (id<SDWebImageOperation>)requestImageWithURL:(NSURL *)url options:(SDWebImageOptions)options context:(SDWebImageContext *)context progress:(SDImageLoaderProgressBlock)progressBlock completed:(SDImageLoaderCompletedBlock)completedBlock {
    
    LPMetadataProvider *provider = [[LPMetadataProvider alloc] init];
    [provider startFetchingMetadataForURL:url completionHandler:^(LPLinkMetadata * _Nullable metadata, NSError * _Nullable error) {
        if (error) {
            if (completedBlock) {
                completedBlock(nil, nil, error, YES);
            }
            return;
        }
        NSItemProvider *imageProvider = metadata.imageProvider;
        if (!imageProvider) {
            // Check icon provider as a backup
            NSItemProvider *iconProvider = metadata.iconProvider;
            if (!iconProvider) {
                // No image to query, failed
                if (completedBlock) {
                    dispatch_main_async_safe(^{
                        NSError *error = [NSError errorWithDomain:SDWebImageLinkErrorDomain code:SDWebImageLinkErrorNoImageProvider userInfo:nil];
                        completedBlock(nil, nil, error, YES);
                    });
                }
                return;
            }
            imageProvider = iconProvider;
        }
        BOOL requestData = [context[SDWebImageContextLinkRequestImageData] boolValue];
        if (requestData) {
            // Request the image data and decode
            [self fetchImageDataWithProvider:imageProvider url:url options:options context:context progress:progressBlock completed:completedBlock];
        } else {
            // Only request the image object, faster
            [self fetchImageWithProvider:imageProvider url:url progress:progressBlock completed:completedBlock];
        }
    }];
    
    return provider;
}

// Fetch image and data with `loadDataRepresentationForTypeIdentifier` API
- (void)fetchImageDataWithProvider:(NSItemProvider *)imageProvider url:(NSURL *)url options:(SDWebImageOptions)options context:(SDWebImageContext *)context progress:(SDImageLoaderProgressBlock)progressBlock completed:(SDImageLoaderCompletedBlock)completedBlock {
    SDImageLinkLoaderContext *loaderContext = [SDImageLinkLoaderContext new];
    loaderContext.url = url;
    loaderContext.progressBlock = progressBlock;
    __block NSProgress *progress;
    progress = [imageProvider loadDataRepresentationForTypeIdentifier:(__bridge NSString *)kUTTypeImage completionHandler:^(NSData * _Nullable data, NSError * _Nullable error) {
        if (progressBlock && progress) {
            [progress removeObserver:self forKeyPath:NSStringFromSelector(@selector(fractionCompleted)) context:(__bridge void *)(loaderContext)];
        }
        if (error) {
            if (completedBlock) {
                dispatch_main_async_safe(^{
                    completedBlock(nil, nil, error, YES);
                });
            }
            return;
        }
        // This is global queue, decode it
        UIImage *image = SDImageLoaderDecodeImageData(data, url, options, context);
        if (!image) {
            error = [NSError errorWithDomain:SDWebImageErrorDomain code:SDWebImageErrorBadImageData userInfo:nil];
        }
        if (completedBlock) {
            dispatch_main_async_safe(^{
                completedBlock(image, data, error, YES);
            });
        }
    }];
    
    if (progressBlock && progress) {
        [progress addObserver:self forKeyPath:NSStringFromSelector(@selector(fractionCompleted)) options:NSKeyValueObservingOptionNew context:(__bridge void *)(loaderContext)];
    }
}

// Fetch image with `loadObjectOfClass` API
- (void)fetchImageWithProvider:(NSItemProvider *)imageProvider url:(NSURL *)url progress:(SDImageLoaderProgressBlock)progressBlock completed:(SDImageLoaderCompletedBlock)completedBlock {
    SDImageLinkLoaderContext *loaderContext = [SDImageLinkLoaderContext new];
    loaderContext.url = url;
    loaderContext.progressBlock = progressBlock;
    __block NSProgress *progress;
    progress = [imageProvider loadObjectOfClass:UIImage.class completionHandler:^(UIImage * _Nullable image, NSError * _Nullable error) {
        if (progressBlock && progress) {
            [progress removeObserver:self forKeyPath:NSStringFromSelector(@selector(fractionCompleted)) context:(__bridge void *)(loaderContext)];
        }
        if (error) {
            if (completedBlock) {
                dispatch_main_async_safe(^{
                    completedBlock(nil, nil, error, YES);
                });
            }
            return;
        }
        NSAssert([image isKindOfClass:UIImage.class], @"NSItemProvider loaded object should be UIImage class");
        if (!image) {
            error = [NSError errorWithDomain:SDWebImageErrorDomain code:SDWebImageErrorBadImageData userInfo:nil];
        }
        if (completedBlock) {
            dispatch_main_async_safe(^{
                completedBlock(image, nil, error, YES);
            });
        }
    }];
    
    if (progressBlock && progress) {
        [progress addObserver:self forKeyPath:NSStringFromSelector(@selector(fractionCompleted)) options:NSKeyValueObservingOptionNew context:(__bridge void *)(loaderContext)];
    }
}

- (BOOL)shouldBlockFailedURLWithURL:(NSURL *)url error:(NSError *)error {
    BOOL shouldBlockFailedURL = NO;
    if ([error.domain isEqualToString:SDWebImageErrorDomain]) {
        shouldBlockFailedURL = (   error.code == SDWebImageErrorInvalidURL
                                || error.code == SDWebImageErrorBadImageData);
    }
    return shouldBlockFailedURL;
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([object isKindOfClass:NSProgress.class]) {
        SDImageLinkLoaderContext *loaderContext = (__bridge id)(context);
        if ([loaderContext isKindOfClass:SDImageLinkLoaderContext.class]) {
            NSURL *url = loaderContext.url;
            SDImageLoaderProgressBlock progressBlock = loaderContext.progressBlock;
            NSProgress *progress = object;
            if (progressBlock) {
                progressBlock(progress.completedUnitCount, progress.totalUnitCount, url);
            }
        } else {
            [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

@end
