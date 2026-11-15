#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// What XCTest has but doesn't publish. Each call checks first and falls back to nothing: the
/// caller then has the public API, slower but stable, so a new Xcode degrades this rather than
/// crashing it. Not App Store material, and the runner never ships with the app.
@interface PhoneRunnerSupport : NSObject
/// Bundle IDs of the apps the accessibility system says are active, frontmost first.
+ (NSArray<NSString *> *)activeBundleIDs;
/// Name and bundle ID of each installed app. Empty where the system no longer answers.
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)installedApps;
/// A touch with no waiting for the app to settle. False if it couldn't be sent.
+ (BOOL)touchAt:(CGPoint)point seconds:(NSTimeInterval)seconds;
+ (BOOL)dragFrom:(CGPoint)start to:(CGPoint)end seconds:(NSTimeInterval)seconds;
@end

NS_ASSUME_NONNULL_END
