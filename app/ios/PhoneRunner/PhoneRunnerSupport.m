#import "PhoneRunnerSupport.h"
#import <objc/message.h>

@implementation PhoneRunnerSupport

/// XCTest reads these before any test runs. Without them it records the screen for the whole of
/// a test that never ends, and the recordings stay behind in the system's storage.
+ (void)load {
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{
    @"DisableDiagnosticScreenRecordings" : @YES,
    @"DisableDiagnosticScreenshots" : @YES,
  }];
}

+ (nullable id)accessibilityClient {
  Class device = NSClassFromString(@"XCUIDevice");
  SEL shared = NSSelectorFromString(@"sharedDevice");
  SEL interface = NSSelectorFromString(@"accessibilityInterface");
  if (![device respondsToSelector:shared]) return nil;
  id instance = ((id(*)(id, SEL))objc_msgSend)(device, shared);
  if (![instance respondsToSelector:interface]) return nil;
  return ((id(*)(id, SEL))objc_msgSend)(instance, interface);
}

+ (nullable NSString *)bundleIDOf:(id)element {
  for (NSString *name in @[ @"bundleIdentifier", @"bundleID" ]) {
    SEL selector = NSSelectorFromString(name);
    if (![element respondsToSelector:selector]) continue;
    id value = ((id(*)(id, SEL))objc_msgSend)(element, selector);
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
  }
  return nil;
}

+ (NSArray<NSString *> *)activeBundleIDs {
  @try {
    id client = [self accessibilityClient];
    SEL active = NSSelectorFromString(@"activeApplications");
    if (![client respondsToSelector:active]) return @[];
    NSArray *apps = ((id(*)(id, SEL))objc_msgSend)(client, active);
    if (![apps isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    for (id app in apps) {
      NSString *identifier = [self bundleIDOf:app];
      if (identifier) [found addObject:identifier];
    }
    return found;
  } @catch (__unused NSException *exception) {
    return @[];
  }
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)installedApps {
  @try {
    Class workspace = NSClassFromString(@"LSApplicationWorkspace");
    SEL shared = NSSelectorFromString(@"defaultWorkspace");
    if (![workspace respondsToSelector:shared]) return @[];
    id instance = ((id(*)(id, SEL))objc_msgSend)(workspace, shared);
    NSArray *proxies = nil;
    for (NSString *name in @[ @"allApplications", @"allInstalledApplications" ]) {
      SEL selector = NSSelectorFromString(name);
      if ([instance respondsToSelector:selector]) {
        proxies = ((id(*)(id, SEL))objc_msgSend)(instance, selector);
        break;
      }
    }
    NSMutableArray *apps = [NSMutableArray array];
    for (id proxy in proxies) {
      NSString *identifier = [self bundleIDOf:proxy];
      if (!identifier) {
        SEL selector = NSSelectorFromString(@"applicationIdentifier");
        if ([proxy respondsToSelector:selector]) identifier = ((id(*)(id, SEL))objc_msgSend)(proxy, selector);
      }
      if (identifier.length == 0) continue;
      NSString *name = identifier;
      SEL localized = NSSelectorFromString(@"localizedName");
      if ([proxy respondsToSelector:localized]) {
        NSString *value = ((id(*)(id, SEL))objc_msgSend)(proxy, localized);
        if ([value isKindOfClass:[NSString class]] && value.length > 0) name = value;
      }
      [apps addObject:@{@"name" : name, @"id" : identifier}];
    }
    return apps;
  } @catch (__unused NSException *exception) {
    return @[];
  }
}

/// A record of one finger's path, or nil if this XCTest has no such thing.
+ (BOOL)synthesize:(void (^)(id path))build at:(CGPoint)point {
  @try {
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    SEL recordInit = NSSelectorFromString(@"initWithName:");
    SEL pathInit = NSSelectorFromString(@"initForTouchAtPoint:offset:");
    SEL add = NSSelectorFromString(@"addPointerEventPath:");
    SEL send = NSSelectorFromString(@"synthesizeWithError:");
    if (![recordClass instancesRespondToSelector:recordInit] || ![pathClass instancesRespondToSelector:pathInit] ||
        ![recordClass instancesRespondToSelector:add] || ![recordClass instancesRespondToSelector:send]) {
      return NO;
    }
    id path = ((id(*)(id, SEL, CGPoint, NSTimeInterval))objc_msgSend)([pathClass alloc], pathInit, point, 0);
    build(path);
    id record = ((id(*)(id, SEL, NSString *))objc_msgSend)([recordClass alloc], recordInit, @"DSH Go");
    ((void (*)(id, SEL, id))objc_msgSend)(record, add, path);
    NSError *error = nil;
    return ((BOOL(*)(id, SEL, NSError **))objc_msgSend)(record, send, &error);
  } @catch (__unused NSException *exception) {
    return NO;
  }
}

+ (BOOL)touchAt:(CGPoint)point seconds:(NSTimeInterval)seconds {
  return [self synthesize:^(id path) {
    ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(path, NSSelectorFromString(@"pressDownAtOffset:"), 0);
    ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(path, NSSelectorFromString(@"liftUpAtOffset:"), seconds);
  } at:point];
}

+ (BOOL)dragFrom:(CGPoint)start to:(CGPoint)end seconds:(NSTimeInterval)seconds {
  return [self synthesize:^(id path) {
    ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(path, NSSelectorFromString(@"pressDownAtOffset:"), 0);
    ((void (*)(id, SEL, CGPoint, NSTimeInterval))objc_msgSend)(path, NSSelectorFromString(@"moveToPoint:atOffset:"), end, seconds);
    ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(path, NSSelectorFromString(@"liftUpAtOffset:"), seconds + 0.05);
  } at:start];
}

@end
