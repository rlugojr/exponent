/*
 *  Copyright (c) 2013, Facebook, Inc.
 *  All rights reserved.
 *
 *  This source code is licensed under the BSD-style license found in the
 *  LICENSE file in the root directory of this source tree. An additional grant
 *  of patent rights can be found in the PATENTS file in the same directory.
 *
 */

#import "ABI10_0_0RCTImagePickerManager.h"
#import "ABI10_0_0RCTImageStoreManager.h"

#import "ABI10_0_0RCTConvert.h"
#import "ABI10_0_0RCTRootView.h"
#import "ABI10_0_0RCTLog.h"
#import "ABI10_0_0RCTUtils.h"

#import <UIKit/UIKit.h>

#import <MobileCoreServices/UTCoreTypes.h>

@interface ABI10_0_0RCTImagePickerManager ()<UIImagePickerControllerDelegate, UINavigationControllerDelegate>

@end

@implementation ABI10_0_0RCTImagePickerManager
{
  NSMutableArray<UIImagePickerController *> *_pickers;
  NSMutableArray<ABI10_0_0RCTResponseSenderBlock> *_pickerCallbacks;
  NSMutableArray<ABI10_0_0RCTResponseSenderBlock> *_pickerCancelCallbacks;
}

ABI10_0_0RCT_EXPORT_MODULE(ImagePickerIOS);

@synthesize bridge = _bridge;

- (dispatch_queue_t)methodQueue
{
  return dispatch_get_main_queue();
}

ABI10_0_0RCT_EXPORT_METHOD(canRecordVideos:(ABI10_0_0RCTResponseSenderBlock)callback)
{
  NSArray<NSString *> *availableMediaTypes = [UIImagePickerController availableMediaTypesForSourceType:UIImagePickerControllerSourceTypeCamera];
  callback(@[@([availableMediaTypes containsObject:(NSString *)kUTTypeMovie])]);
}

ABI10_0_0RCT_EXPORT_METHOD(canUseCamera:(ABI10_0_0RCTResponseSenderBlock)callback)
{
  callback(@[@([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera])]);
}

ABI10_0_0RCT_EXPORT_METHOD(openCameraDialog:(NSDictionary *)config
                  successCallback:(ABI10_0_0RCTResponseSenderBlock)callback
                  cancelCallback:(ABI10_0_0RCTResponseSenderBlock)cancelCallback)
{
  if (ABI10_0_0RCTRunningInAppExtension()) {
    cancelCallback(@[@"Camera access is unavailable in an app extension"]);
    return;
  }

  UIImagePickerController *imagePicker = [UIImagePickerController new];
  imagePicker.delegate = self;
  imagePicker.sourceType = UIImagePickerControllerSourceTypeCamera;

  if ([ABI10_0_0RCTConvert BOOL:config[@"videoMode"]]) {
    imagePicker.cameraCaptureMode = UIImagePickerControllerCameraCaptureModeVideo;
  }

  [self _presentPicker:imagePicker
       successCallback:callback
        cancelCallback:cancelCallback];
}

ABI10_0_0RCT_EXPORT_METHOD(openSelectDialog:(NSDictionary *)config
                  successCallback:(ABI10_0_0RCTResponseSenderBlock)callback
                  cancelCallback:(ABI10_0_0RCTResponseSenderBlock)cancelCallback)
{
  if (ABI10_0_0RCTRunningInAppExtension()) {
    cancelCallback(@[@"Image picker is currently unavailable in an app extension"]);
    return;
  }

  UIImagePickerController *imagePicker = [UIImagePickerController new];
  imagePicker.delegate = self;
  imagePicker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;

  NSMutableArray<NSString *> *allowedTypes = [NSMutableArray new];
  if ([ABI10_0_0RCTConvert BOOL:config[@"showImages"]]) {
    [allowedTypes addObject:(NSString *)kUTTypeImage];
  }
  if ([ABI10_0_0RCTConvert BOOL:config[@"showVideos"]]) {
    [allowedTypes addObject:(NSString *)kUTTypeMovie];
  }

  imagePicker.mediaTypes = allowedTypes;

  [self _presentPicker:imagePicker
       successCallback:callback
        cancelCallback:cancelCallback];
}

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary<NSString *, id> *)info
{
  NSString *mediaType = info[UIImagePickerControllerMediaType];
  BOOL isMovie = [mediaType isEqualToString:(NSString *)kUTTypeMovie];
  NSString *key = isMovie ? UIImagePickerControllerMediaURL : UIImagePickerControllerReferenceURL;
  NSURL *imageURL = info[key];
  UIImage *image = info[UIImagePickerControllerOriginalImage];
  NSNumber *width = 0;
  NSNumber *height = 0;
  if (image) {
    height = @(image.size.height);
    width = @(image.size.width);
  }
  if (imageURL) {
    [self _dismissPicker:picker args:@[imageURL.absoluteString, ABI10_0_0RCTNullIfNil(height), ABI10_0_0RCTNullIfNil(width)]];
    return;
  }

  // This is a newly taken image, and doesn't have a URL yet.
  // We need to save it to the image store first.
  UIImage *originalImage = info[UIImagePickerControllerOriginalImage];

  // WARNING: Using ImageStoreManager may cause a memory leak because the
  // image isn't automatically removed from store once we're done using it.
  [_bridge.imageStoreManager storeImage:originalImage withBlock:^(NSString *tempImageTag) {
    [self _dismissPicker:picker args:tempImageTag ? @[tempImageTag, height, width] : nil];
  }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
  [self _dismissPicker:picker args:nil];
}

- (void)_presentPicker:(UIImagePickerController *)imagePicker
       successCallback:(ABI10_0_0RCTResponseSenderBlock)callback
        cancelCallback:(ABI10_0_0RCTResponseSenderBlock)cancelCallback
{
  if (!_pickers) {
    _pickers = [NSMutableArray new];
    _pickerCallbacks = [NSMutableArray new];
    _pickerCancelCallbacks = [NSMutableArray new];
  }

  [_pickers addObject:imagePicker];
  [_pickerCallbacks addObject:callback];
  [_pickerCancelCallbacks addObject:cancelCallback];

  UIViewController *rootViewController = ABI10_0_0RCTPresentedViewController();
  [rootViewController presentViewController:imagePicker animated:YES completion:nil];
}

- (void)_dismissPicker:(UIImagePickerController *)picker args:(NSArray *)args
{
  NSUInteger index = [_pickers indexOfObject:picker];
  ABI10_0_0RCTResponseSenderBlock successCallback = _pickerCallbacks[index];
  ABI10_0_0RCTResponseSenderBlock cancelCallback = _pickerCancelCallbacks[index];

  [_pickers removeObjectAtIndex:index];
  [_pickerCallbacks removeObjectAtIndex:index];
  [_pickerCancelCallbacks removeObjectAtIndex:index];

  UIViewController *rootViewController = ABI10_0_0RCTPresentedViewController();
  [rootViewController dismissViewControllerAnimated:YES completion:nil];

  if (args) {
    successCallback(args);
  } else {
    cancelCallback(@[]);
  }
}

@end
