/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "ABI8_0_0RCTComponentData.h"

#import <objc/message.h>

#import "ABI8_0_0RCTBridge.h"
#import "ABI8_0_0RCTConvert.h"
#import "ABI8_0_0RCTShadowView.h"
#import "ABI8_0_0RCTUtils.h"
#import "UIView+ReactABI8_0_0.h"

typedef void (^ABI8_0_0RCTPropBlock)(id<ABI8_0_0RCTComponent> view, id json);

@interface ABI8_0_0RCTComponentProp : NSObject

@property (nonatomic, copy, readonly) NSString *type;
@property (nonatomic, copy) ABI8_0_0RCTPropBlock propBlock;

@end

@implementation ABI8_0_0RCTComponentProp

- (instancetype)initWithType:(NSString *)type
{
  if ((self = [super init])) {
    _type = [type copy];
  }
  return self;
}

@end

@implementation ABI8_0_0RCTComponentData
{
  id<ABI8_0_0RCTComponent> _defaultView; // Only needed for ABI8_0_0RCT_CUSTOM_VIEW_PROPERTY
  NSMutableDictionary<NSString *, ABI8_0_0RCTPropBlock> *_viewPropBlocks;
  NSMutableDictionary<NSString *, ABI8_0_0RCTPropBlock> *_shadowPropBlocks;
  BOOL _implementsUIBlockToAmendWithShadowViewRegistry;
  __weak ABI8_0_0RCTBridge *_bridge;
}

@synthesize manager = _manager;

- (instancetype)initWithManagerClass:(Class)managerClass
                              bridge:(ABI8_0_0RCTBridge *)bridge
{
  if ((self = [super init])) {
    _bridge = bridge;
    _managerClass = managerClass;
    _viewPropBlocks = [NSMutableDictionary new];
    _shadowPropBlocks = [NSMutableDictionary new];

    _name = ABI8_0_0RCTBridgeModuleNameForClass(_managerClass);
    ABI8_0_0RCTAssert(_name.length, @"Invalid moduleName '%@'", _name);
    if ([_name hasSuffix:@"Manager"]) {
      _name = [_name substringToIndex:_name.length - @"Manager".length];
    }

    _implementsUIBlockToAmendWithShadowViewRegistry = NO;
    Class cls = _managerClass;
    while (cls != [ABI8_0_0RCTViewManager class]) {
      _implementsUIBlockToAmendWithShadowViewRegistry = _implementsUIBlockToAmendWithShadowViewRegistry ||
      ABI8_0_0RCTClassOverridesInstanceMethod(cls, @selector(uiBlockToAmendWithShadowViewRegistry:));
      cls = [cls superclass];
    }
  }
  return self;
}

- (ABI8_0_0RCTViewManager *)manager
{
  if (!_manager) {
    _manager = [_bridge moduleForClass:_managerClass];
  }
  return _manager;
}

ABI8_0_0RCT_NOT_IMPLEMENTED(- (instancetype)init)

- (UIView *)createViewWithTag:(NSNumber *)tag
{
  ABI8_0_0RCTAssertMainQueue();

  UIView *view = [self.manager view];
  view.ReactABI8_0_0Tag = tag;
  view.multipleTouchEnabled = YES;
  view.userInteractionEnabled = YES; // required for touch handling
  view.layer.allowsGroupOpacity = YES; // required for touch handling
  return view;
}

- (ABI8_0_0RCTShadowView *)createShadowViewWithTag:(NSNumber *)tag
{
  ABI8_0_0RCTShadowView *shadowView = [self.manager shadowView];
  shadowView.ReactABI8_0_0Tag = tag;
  shadowView.viewName = _name;
  return shadowView;
}

- (ABI8_0_0RCTPropBlock)propBlockForKey:(NSString *)name
                   inDictionary:(NSMutableDictionary<NSString *, ABI8_0_0RCTPropBlock> *)propBlocks
{
  BOOL shadowView = (propBlocks == _shadowPropBlocks);
  ABI8_0_0RCTPropBlock propBlock = propBlocks[name];
  if (!propBlock) {

    __weak ABI8_0_0RCTComponentData *weakSelf = self;

    // Get type
    SEL type = NULL;
    NSString *keyPath = nil;
    SEL selector = NSSelectorFromString([NSString stringWithFormat:@"propConfig%@_%@", shadowView ? @"Shadow" : @"", name]);
    if ([_managerClass respondsToSelector:selector]) {
      NSArray<NSString *> *typeAndKeyPath =
        ((NSArray<NSString *> *(*)(id, SEL))objc_msgSend)(_managerClass, selector);
      type = ABI8_0_0RCTConvertSelectorForType(typeAndKeyPath[0]);
      keyPath = typeAndKeyPath.count > 1 ? typeAndKeyPath[1] : nil;
    } else {
      propBlock = ^(__unused id view, __unused id json) {};
      propBlocks[name] = propBlock;
      return propBlock;
    }

    // Check for custom setter
    if ([keyPath isEqualToString:@"__custom__"]) {

      // Get custom setter
      SEL customSetter = NSSelectorFromString([NSString stringWithFormat:@"set_%@:for%@View:withDefaultView:", name, shadowView ? @"Shadow" : @""]);

      propBlock = ^(id<ABI8_0_0RCTComponent> view, id json) {
        ABI8_0_0RCTComponentData *strongSelf = weakSelf;
        if (!strongSelf) {
          return;
        }
        json = ABI8_0_0RCTNilIfNull(json);
        if (!json && !strongSelf->_defaultView) {
          // Only create default view if json is null
          strongSelf->_defaultView = [strongSelf createViewWithTag:nil];
        }
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(
          strongSelf.manager, customSetter, json, view, strongSelf->_defaultView
        );
      };

    } else {

      // Disect keypath
      NSString *key = name;
      NSArray<NSString *> *parts = [keyPath componentsSeparatedByString:@"."];
      if (parts) {
        key = parts.lastObject;
        parts = [parts subarrayWithRange:(NSRange){0, parts.count - 1}];
      }

      // Get property getter
      SEL getter = NSSelectorFromString(key);

      // Get property setter
      SEL setter = NSSelectorFromString([NSString stringWithFormat:@"set%@%@:",
                                         [key substringToIndex:1].uppercaseString,
                                         [key substringFromIndex:1]]);

      // Build setter block
      void (^setterBlock)(id target, id json) = nil;
      if (type == NSSelectorFromString(@"ABI8_0_0RCTBubblingEventBlock:") ||
          type == NSSelectorFromString(@"ABI8_0_0RCTDirectEventBlock:")) {

        // Special case for event handlers
        __weak ABI8_0_0RCTViewManager *weakManager = self.manager;
        setterBlock = ^(id target, id json) {
          __weak id<ABI8_0_0RCTComponent> weakTarget = target;
          ((void (*)(id, SEL, id))objc_msgSend)(target, setter, [ABI8_0_0RCTConvert BOOL:json] ? ^(NSDictionary *body) {
            body = [NSMutableDictionary dictionaryWithDictionary:body];
            ((NSMutableDictionary *)body)[@"target"] = weakTarget.ReactABI8_0_0Tag;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [weakManager.bridge.eventDispatcher sendInputEventWithName:ABI8_0_0RCTNormalizeInputEventName(name) body:body];
#pragma clang diagnostic pop
          } : nil);
        };

      } else {

        // Ordinary property handlers
        NSMethodSignature *typeSignature = [[ABI8_0_0RCTConvert class] methodSignatureForSelector:type];
        if (!typeSignature) {
          ABI8_0_0RCTLogError(@"No +[ABI8_0_0RCTConvert %@] function found.", NSStringFromSelector(type));
          return ^(__unused id<ABI8_0_0RCTComponent> view, __unused id json){};
        }
        switch (typeSignature.methodReturnType[0]) {

  #define ABI8_0_0RCT_CASE(_value, _type) \
          case _value: { \
            __block BOOL setDefaultValue = NO; \
            __block _type defaultValue; \
            _type (*convert)(id, SEL, id) = (typeof(convert))objc_msgSend; \
            _type (*get)(id, SEL) = (typeof(get))objc_msgSend; \
            void (*set)(id, SEL, _type) = (typeof(set))objc_msgSend; \
            setterBlock = ^(id target, id json) { \
              if (json) { \
                if (!setDefaultValue && target) { \
                  if ([target respondsToSelector:getter]) { \
                    defaultValue = get(target, getter); \
                  } \
                  setDefaultValue = YES; \
                } \
                set(target, setter, convert([ABI8_0_0RCTConvert class], type, json)); \
              } else if (setDefaultValue) { \
                set(target, setter, defaultValue); \
              } \
            }; \
            break; \
          }

            ABI8_0_0RCT_CASE(_C_SEL, SEL)
            ABI8_0_0RCT_CASE(_C_CHARPTR, const char *)
            ABI8_0_0RCT_CASE(_C_CHR, char)
            ABI8_0_0RCT_CASE(_C_UCHR, unsigned char)
            ABI8_0_0RCT_CASE(_C_SHT, short)
            ABI8_0_0RCT_CASE(_C_USHT, unsigned short)
            ABI8_0_0RCT_CASE(_C_INT, int)
            ABI8_0_0RCT_CASE(_C_UINT, unsigned int)
            ABI8_0_0RCT_CASE(_C_LNG, long)
            ABI8_0_0RCT_CASE(_C_ULNG, unsigned long)
            ABI8_0_0RCT_CASE(_C_LNG_LNG, long long)
            ABI8_0_0RCT_CASE(_C_ULNG_LNG, unsigned long long)
            ABI8_0_0RCT_CASE(_C_FLT, float)
            ABI8_0_0RCT_CASE(_C_DBL, double)
            ABI8_0_0RCT_CASE(_C_BOOL, BOOL)
            ABI8_0_0RCT_CASE(_C_PTR, void *)
            ABI8_0_0RCT_CASE(_C_ID, id)

          case _C_STRUCT_B:
          default: {

            NSInvocation *typeInvocation = [NSInvocation invocationWithMethodSignature:typeSignature];
            typeInvocation.selector = type;
            typeInvocation.target = [ABI8_0_0RCTConvert class];

            __block NSInvocation *targetInvocation = nil;
            __block NSMutableData *defaultValue = nil;

            setterBlock = ^(id target, id json) { \

              if (!target) {
                return;
              }

              // Get default value
              if (!defaultValue) {
                if (!json) {
                  // We only set the defaultValue when we first pass a non-null
                  // value, so if the first value sent for a prop is null, it's
                  // a no-op (we'd be resetting it to its default when its
                  // value is already the default).
                  return;
                }
                // Use NSMutableData to store defaultValue instead of malloc, so
                // it will be freed automatically when setterBlock is released.
                defaultValue = [[NSMutableData alloc] initWithLength:typeSignature.methodReturnLength];
                if ([target respondsToSelector:getter]) {
                  NSMethodSignature *signature = [target methodSignatureForSelector:getter];
                  NSInvocation *sourceInvocation = [NSInvocation invocationWithMethodSignature:signature];
                  sourceInvocation.selector = getter;
                  [sourceInvocation invokeWithTarget:target];
                  [sourceInvocation getReturnValue:defaultValue.mutableBytes];
                }
              }

              // Get value
              BOOL freeValueOnCompletion = NO;
              void *value = defaultValue.mutableBytes;
              if (json) {
                freeValueOnCompletion = YES;
                value = malloc(typeSignature.methodReturnLength);
                [typeInvocation setArgument:&json atIndex:2];
                [typeInvocation invoke];
                [typeInvocation getReturnValue:value];
              }

              // Set value
              if (!targetInvocation) {
                NSMethodSignature *signature = [target methodSignatureForSelector:setter];
                targetInvocation = [NSInvocation invocationWithMethodSignature:signature];
                targetInvocation.selector = setter;
              }
              [targetInvocation setArgument:value atIndex:2];
              [targetInvocation invokeWithTarget:target];
              if (freeValueOnCompletion) {
                // Only free the value if we `malloc`d it locally, otherwise it
                // points to `defaultValue.mutableBytes`, which is managed by ARC.
                free(value);
              }
            };
            break;
          }
        }
      }

      propBlock = ^(__unused id view, __unused id json) {

        // Follow keypath
        id target = view;
        for (NSString *part in parts) {
          target = [target valueForKey:part];
        }

        // Set property with json
        setterBlock(target, ABI8_0_0RCTNilIfNull(json));
      };
    }

    if (ABI8_0_0RCT_DEBUG) {

      // Provide more useful log feedback if there's an error
      ABI8_0_0RCTPropBlock unwrappedBlock = propBlock;
      propBlock = ^(id<ABI8_0_0RCTComponent> view, id json) {
        NSString *logPrefix = [NSString stringWithFormat:
                               @"Error setting property '%@' of %@ with tag #%@: ",
                               name, weakSelf.name, view.ReactABI8_0_0Tag];

        ABI8_0_0RCTPerformBlockWithLogPrefix(^{ unwrappedBlock(view, json); }, logPrefix);
      };
    }

    propBlocks[name] = [propBlock copy];
  }
  return propBlock;
}

- (void)setProps:(NSDictionary<NSString *, id> *)props forView:(id<ABI8_0_0RCTComponent>)view
{
  if (!view) {
    return;
  }

  [props enumerateKeysAndObjectsUsingBlock:^(NSString *key, id json, __unused BOOL *stop) {
    [self propBlockForKey:key inDictionary:self->_viewPropBlocks](view, json);
  }];

  if ([view respondsToSelector:@selector(didSetProps:)]) {
    [view didSetProps:[props allKeys]];
  }
}

- (void)setProps:(NSDictionary<NSString *, id> *)props forShadowView:(ABI8_0_0RCTShadowView *)shadowView
{
  if (!shadowView) {
    return;
  }

  [props enumerateKeysAndObjectsUsingBlock:^(NSString *key, id json, __unused BOOL *stop) {
    [self propBlockForKey:key inDictionary:self->_shadowPropBlocks](shadowView, json);
  }];

  if ([shadowView respondsToSelector:@selector(didSetProps:)]) {
    [shadowView didSetProps:[props allKeys]];
  }
}

- (NSDictionary<NSString *, id> *)viewConfig
{
  NSMutableArray<NSString *> *directEvents = [NSMutableArray new];
  if (ABI8_0_0RCTClassOverridesInstanceMethod(_managerClass, @selector(customDirectEventTypes))) {
    NSArray<NSString *> *events = [self.manager customDirectEventTypes];
    if (ABI8_0_0RCT_DEBUG) {
      ABI8_0_0RCTAssert(!events || [events isKindOfClass:[NSArray class]],
        @"customDirectEventTypes must return an array, but %@ returned %@",
        _managerClass, [events class]);
    }
    for (NSString *event in events) {
      [directEvents addObject:ABI8_0_0RCTNormalizeInputEventName(event)];
    }
  }

  NSMutableArray<NSString *> *bubblingEvents = [NSMutableArray new];
  if (ABI8_0_0RCTClassOverridesInstanceMethod(_managerClass, @selector(customBubblingEventTypes))) {
    NSArray<NSString *> *events = [self.manager customBubblingEventTypes];
    if (ABI8_0_0RCT_DEBUG) {
      ABI8_0_0RCTAssert(!events || [events isKindOfClass:[NSArray class]],
        @"customBubblingEventTypes must return an array, but %@ returned %@",
        _managerClass, [events class]);
    }
    for (NSString *event in events) {
      [bubblingEvents addObject:ABI8_0_0RCTNormalizeInputEventName(event)];
    }
  }

  unsigned int count = 0;
  NSMutableDictionary *propTypes = [NSMutableDictionary new];
  Method *methods = class_copyMethodList(object_getClass(_managerClass), &count);
  for (unsigned int i = 0; i < count; i++) {
    Method method = methods[i];
    SEL selector = method_getName(method);
    NSString *methodName = NSStringFromSelector(selector);
    if ([methodName hasPrefix:@"propConfig"]) {
      NSRange nameRange = [methodName rangeOfString:@"_"];
      if (nameRange.length) {
        NSString *name = [methodName substringFromIndex:nameRange.location + 1];
        NSString *type = ((NSArray<NSString *> *(*)(id, SEL))objc_msgSend)(_managerClass, selector)[0];
        if (ABI8_0_0RCT_DEBUG && propTypes[name] && ![propTypes[name] isEqualToString:type]) {
          ABI8_0_0RCTLogError(@"Property '%@' of component '%@' redefined from '%@' "
                      "to '%@'", name, _name, propTypes[name], type);
        }

        if ([type isEqualToString:@"ABI8_0_0RCTBubblingEventBlock"]) {
          [bubblingEvents addObject:ABI8_0_0RCTNormalizeInputEventName(name)];
          propTypes[name] = @"BOOL";
        } else if ([type isEqualToString:@"ABI8_0_0RCTDirectEventBlock"]) {
          [directEvents addObject:ABI8_0_0RCTNormalizeInputEventName(name)];
          propTypes[name] = @"BOOL";
        } else {
          propTypes[name] = type;
        }
      }
    }
  }
  free(methods);

  if (ABI8_0_0RCT_DEBUG) {
    for (NSString *event in directEvents) {
      if ([bubblingEvents containsObject:event]) {
        ABI8_0_0RCTLogError(@"Component '%@' registered '%@' as both a bubbling event "
                    "and a direct event", _name, event);
      }
    }
    for (NSString *event in bubblingEvents) {
      if ([directEvents containsObject:event]) {
        ABI8_0_0RCTLogError(@"Component '%@' registered '%@' as both a bubbling event "
                    "and a direct event", _name, event);
      }
    }
  }

  return @{
    @"propTypes" : propTypes,
    @"directEvents" : directEvents,
    @"bubblingEvents" : bubblingEvents,
  };
}

- (ABI8_0_0RCTViewManagerUIBlock)uiBlockToAmendWithShadowViewRegistry:(NSDictionary<NSNumber *, ABI8_0_0RCTShadowView *> *)registry
{
  if (_implementsUIBlockToAmendWithShadowViewRegistry) {
    return [[self manager] uiBlockToAmendWithShadowViewRegistry:registry];
  }
  return nil;
}

@end
