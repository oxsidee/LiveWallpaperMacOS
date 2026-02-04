/*
 * This file is part of LiveWallpaper – LiveWallpaper App for macOS.
 * Copyright (C) 2025 Bios thusvill
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#include <AppKit/AppKit.h>

#import <IOKit/graphics/IOGraphicsLib.h>

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#include <Foundation/Foundation.h>
#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#import <QuartzCore/QuartzCore.h>
#include <cmath>
#include <cstdlib>
#include <float.h>

@interface VideoWallpaperDaemon : NSObject
@property(strong) NSMutableArray<NSWindow *> *windows;
@property(strong) NSMutableArray<AVQueuePlayer *> *players;
@property(strong) NSMutableArray<AVPlayerLayer *> *playerLayers;
@property(strong) NSMutableArray<AVPlayerLooper *> *loopers;
@property(nonatomic, assign) BOOL autoPauseEnabled;
@property(nonatomic, assign) BOOL wasPlayingBeforeSleep;
@property(nonatomic, assign) BOOL screen_locked;

@property(nonatomic, assign) NSInteger scalingMode;
@property(nonatomic, strong) NSString *framePath;
@property(nonatomic, assign) NSScreen *targetScreen;
@property(nonatomic, assign) AVAsset *asset;
@property(nonatomic, assign) CGFloat targetPlaybackRate;
@property(nonatomic, assign) BOOL reducedPerformanceMode;
@property(nonatomic, assign) CGDirectDisplayID targetDisplayID;
@property(nonatomic, assign) BOOL runningOnBattery;
@property(nonatomic, assign) BOOL lowPowerModeEnabled;
@property(nonatomic, assign) BOOL visibilityReductionActive;
@property(nonatomic, assign) BOOL playbackPaused;
@property(nonatomic, strong) NSString *currentVideoPath;
@property(nonatomic, assign) BOOL isTransitioning;
@property(nonatomic, assign) NSTimeInterval videoStartTime;
@property(nonatomic, assign) NSTimeInterval videoDuration;
@property(nonatomic, strong) id loopEndTimeObserver;
@property(nonatomic, assign) BOOL didFireEndNotificationThisLoop;

- (instancetype)initWithVideo:(NSString *)videoPath
                  frameOutput:(NSString *)framePath
                  scalingMode:(NSInteger)scalingMode
                 targetScreen:(NSScreen *)targetScreen;
- (void)checkAndUpdatePlaybackState;
- (void)transitionToVideo:(NSString *)newVideoPath withImagePath:(NSString *)newImagePath;
@end

// Crossfade duration in seconds
static const CGFloat kCrossfadeDuration = 1.5;

@implementation VideoWallpaperDaemon

- (instancetype)initWithVideo:(NSString *)videoPath
                  frameOutput:(NSString *)framePath
                  scalingMode:(NSInteger)scalingMode
                 targetScreen:(NSScreen *)targetScreen {
  self = [super init];
  if (self) {
    _windows = [NSMutableArray array];
    _players = [NSMutableArray array];
    _playerLayers = [NSMutableArray array];
    _loopers = [NSMutableArray array];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    //    if ([defaults objectForKey:@"pauseOnAppFocus"] == nil) {
    //      [defaults setBool:YES forKey:@"pauseOnAppFocus"];
    //      [defaults synchronize];
    //    }
    _autoPauseEnabled = [defaults boolForKey:@"pauseOnAppFocus"];
    _wasPlayingBeforeSleep = YES;
    _scalingMode = scalingMode ?: 0;
    _framePath = framePath;
    _targetScreen = targetScreen;
    _targetPlaybackRate = 1.0f;
    _reducedPerformanceMode = NO;

    NSNumber *screenNumber = targetScreen.deviceDescription[@"NSScreenNumber"];
    _targetDisplayID = screenNumber
                           ? (CGDirectDisplayID)screenNumber.unsignedIntValue
                           : kCGNullDirectDisplay;
    _runningOnBattery = [self isRunningOnBatteryPower];
    _lowPowerModeEnabled = [self currentLowPowerModeState];
    _visibilityReductionActive = NO;
    _playbackPaused = NO;

    // Observe screen lock/unlock
    NSDistributedNotificationCenter *center =
        [NSDistributedNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(screenLocked:)
                   name:@"com.apple.screenIsLocked"
                 object:nil];
    [center addObserver:self
               selector:@selector(screenUnlocked:)
                   name:@"com.apple.screenIsUnlocked"
                 object:nil];

    // Observe active application changes for auto-pause feature
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(activeApplicationChanged:)
               name:NSWorkspaceDidActivateApplicationNotification
             object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(activeSpaceChanged:)
               name:NSWorkspaceActiveSpaceDidChangeNotification
             object:nil];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(powerStateDidChange:)
               name:NSProcessInfoPowerStateDidChangeNotification
             object:nil];

    // Setup wallpaper with video
    [self setupWallpaperWithVideo:videoPath];

    [self updatePerformanceMode];
    [self checkAndUpdatePlaybackState];
  }
  return self;
}
- (void)setupWallpaperWithVideo:(NSString *)videoPath {
  _currentVideoPath = videoPath;
  _isTransitioning = NO;

  NSURL *videoURL = [NSURL fileURLWithPath:videoPath];
  
  // Store start time for sync across displays
  // Use video path as key so all daemons with same video sync together
  NSString *startTimeKey = [NSString stringWithFormat:@"VideoStartTime_%@", 
      [[videoPath lastPathComponent] stringByDeletingPathExtension]];
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults synchronize];
  
  NSTimeInterval existingStartTime = [defaults doubleForKey:startTimeKey];
  if (existingStartTime == 0) {
    // First daemon to start this video - record start time
    _videoStartTime = [NSDate timeIntervalSinceReferenceDate];
    [defaults setDouble:_videoStartTime forKey:startTimeKey];
    [defaults synchronize];
  } else {
    // Another daemon already started this video - use same start time
    _videoStartTime = existingStartTime;
  }
  
  // Get video duration for sync calculation
  AVAsset *tempAsset = [AVAsset assetWithURL:videoURL];
  _videoDuration = CMTimeGetSeconds(tempAsset.duration);
  if (_videoDuration <= 0) {
    _videoDuration = 0; // Will be updated when asset loads
  }

  NSRect visibleFrame = _targetScreen.frame;

  NSWindow *window =
      [[NSWindow alloc] initWithContentRect:visibleFrame
                                  styleMask:NSWindowStyleMaskBorderless
                                    backing:NSBackingStoreBuffered
                                      defer:NO
                                     screen:_targetScreen];

  window.level = kCGDesktopWindowLevel - 1;
  // window.level = CGWindowLevelForKey(kCGDesktopWindowLevelKey - 1);

  [window setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorFullScreenAuxiliary |
                                NSWindowCollectionBehaviorStationary |
                                NSWindowCollectionBehaviorIgnoresCycle];

  [window setOpaque:NO];
  [window setBackgroundColor:[NSColor clearColor]];

  [window setHasShadow:NO];
  [window.contentView setWantsLayer:YES];

  //[window orderFrontRegardless];
  [window setSharingType:NSWindowSharingNone];

  [window setIgnoresMouseEvents:YES];

  _asset = [AVAsset assetWithURL:videoURL];
  // Use URL-based init to work around AVTelemetryInterval bug in macOS 26
  AVPlayerItem *item = [[AVPlayerItem alloc] initWithURL:videoURL];
  AVQueuePlayer *player = [AVQueuePlayer queuePlayerWithItems:@[]];
  AVPlayerLooper *looper = [AVPlayerLooper playerLooperWithPlayer:player
                                                     templateItem:item];

  [window.contentView setWantsLayer:YES];
  AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:player];
  NSInteger _scalingMode = [defaults integerForKey:@"scale_mode"];

  switch (_scalingMode) {

  case 1: // fit
    layer.videoGravity = AVLayerVideoGravityResizeAspect;
    break;

  case 2: // stretch
    layer.videoGravity = AVLayerVideoGravityResize;
    break;

  case 3: // center
    layer.videoGravity = AVLayerVideoGravityResizeAspect;
    layer.anchorPoint = CGPointMake(0.5, 0.5);
    layer.position =
        CGPointMake(CGRectGetMidX(visibleFrame), CGRectGetMidY(visibleFrame));
    break;

  case 0: // fill
  case 4: // height-fill (same behavior for video)
    layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    break;

  default:
    layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    break;
  }
  if (_scalingMode != 3) {
    layer.frame = window.contentView.bounds;
    layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
  }

  layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
  layer.needsDisplayOnBoundsChange = NO;
  layer.actions = @{@"contents" : [NSNull null]};
  layer.drawsAsynchronously = YES; // Offload drawing to background thread
  layer.contentsScale = 1.0f; // 1x scale is enough for fullscreen wallpaper
  [window.contentView.layer addSublayer:layer];

  [window setFrame:visibleFrame display:YES];

  [window makeKeyAndOrderFront:nil];

  player.volume =
      [[NSUserDefaults standardUserDefaults] floatForKey:@"wallpapervolume"];
  player.muted = NO;
  [player play];
  
  // Observe loop end for slideshow (AVPlayerLooper never fires DidPlayToEndTime)
  [self addLoopEndObserverForPlayer:player];

  // Limit decode resolution to logical screen size (not Retina physical pixels)
  // This reduces GPU load significantly on high-DPI displays
  CGFloat maxWidth = MIN(_targetScreen.frame.size.width, 2560.0f);
  CGFloat maxHeight = MIN(_targetScreen.frame.size.height, 1440.0f);
  player.currentItem.preferredMaximumResolution = CGSizeMake(maxWidth, maxHeight);
  player.currentItem.preferredForwardBufferDuration = 2.0; // Reduce buffer from default ~10s

  [_windows addObject:window];
  [_players addObject:player];
  [_playerLayers addObject:layer];
  [_loopers addObject:looper];

  NSLog(@"✅ Screen %@ visibleFrame: %@", _targetScreen,
        NSStringFromRect(visibleFrame));

  [self setStaticWallpaper];
}

- (void)screenLocked:(NSNotification *)note {
  // Save current playback state
  self.wasPlayingBeforeSleep = (_players.firstObject.rate > 0);
  NSLog(@"[Daemon] Screen locked - saving playback state: %@",
        self.wasPlayingBeforeSleep ? @"playing" : @"paused");

  self.screen_locked = true;

  for (AVQueuePlayer *player in _players) {
    [player pause];
  }
}

- (void)screenUnlocked:(NSNotification *)note {
  NSLog(@"[Daemon] Screen unlocked");

  self.screen_locked = false;
  // Resume if it was playing before sleep
  if (self.wasPlayingBeforeSleep) {
    NSLog(@"[Daemon] Resuming playback after screen unlock");
    [self resumeAllPlayers];
  }

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self checkAndUpdatePlaybackState];
      });
}
- (void)dealloc {
  [self removeLoopEndObserver];
  for (NSWindow *window in _windows) {
    [window setReleasedWhenClosed:YES];
    [window close];
  }
  [_windows removeAllObjects];
  [_players removeAllObjects];
  [_playerLayers removeAllObjects];
  [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
}

static void terminateWallpaperDaemonCallback(CFNotificationCenterRef center,
                                             void *observer, CFStringRef name,
                                             const void *object,
                                             CFDictionaryRef userInfo) {
  VideoWallpaperDaemon *daemon = (__bridge VideoWallpaperDaemon *)observer;
  [daemon terminateWallpaperDaemon];
}

- (void)terminateWallpaperDaemon {
  NSLog(@"Received terminate notification");
  for (NSWindow *window in _windows) {
    [window setReleasedWhenClosed:YES];
    [window close];
  }
  [_windows removeAllObjects];
  [_players removeAllObjects];
  [_playerLayers removeAllObjects];
  [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
  exit(0);
}

// - (BOOL)shouldPlayWallpaper {
//   // If auto-pause is disabled, always play

//   NSRunningApplication *activeApp =
//       [[NSWorkspace sharedWorkspace] frontmostApplication];

//   // Check if Finder or our app is active - always play
//   if ([activeApp.bundleIdentifier isEqualToString:@"com.apple.finder"] ||
//       [activeApp.bundleIdentifier
//           isEqualToString:@"com.thusvill.LiveWallpaper"]) {
//     return YES;
//   }

//   // Check if the active app is hidden (Cmd+H)
//   if (activeApp.isHidden) {
//     return YES;
//   }

//   if (self.screen_locked) {
//     return NO;
//   }

//   // Get all on-screen windows (this excludes minimized windows)
//   CFArrayRef windowList = CGWindowListCopyWindowInfo(
//       kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
//       kCGNullWindowID);
//   BOOL hasVisibleAppWindow = NO;

//   if (windowList) {
//     NSArray *windows = (__bridge NSArray *)windowList;
//     pid_t activePID = activeApp.processIdentifier;

//     for (NSDictionary *window in windows) {
//       NSNumber *ownerPID = window[(NSString *)kCGWindowOwnerPID];
//       NSNumber *layer = window[(NSString *)kCGWindowLayer];

//       // Check if this window belongs to the active app and is a normal
//       window
//       // (layer 0)
//       if (ownerPID && [ownerPID intValue] == activePID && layer &&
//           [layer intValue] == 0) {

//         // Check if window has meaningful bounds
//         NSDictionary *bounds = window[(NSString *)kCGWindowBounds];
//         if (bounds) {
//           CGRect rect;
//           CGRectMakeWithDictionaryRepresentation(
//               (__bridge CFDictionaryRef)bounds, &rect);

//           // If window is reasonably sized, it's visible
//           if (rect.size.width > 50 && rect.size.height > 50) {
//             hasVisibleAppWindow = YES;
//             break;
//           }
//         }
//       }
//     }
//     CFRelease(windowList);
//   }

//   // Play if no visible windows from the active app
//   return !hasVisibleAppWindow;
// }

- (void)checkAndUpdatePlaybackState {
  BOOL screenLocked = self.screen_locked || [self isScreenLocked];
  self.screen_locked = screenLocked;

  // Check if fullscreen app covers wallpaper on this display
  BOOL wallpaperHidden = [self isWallpaperHiddenOnTargetDisplay];

  BOOL shouldPause = screenLocked || wallpaperHidden;

  if (!shouldPause && self.autoPauseEnabled) {
    shouldPause = ![self isFrontmostAppAllowed];
  }

  if (shouldPause) {
    if (!self.playbackPaused) {
      NSLog(@"[Daemon] Pausing because hidden=%@ locked=%@ autoPause=%@",
            wallpaperHidden ? @"YES" : @"NO", screenLocked ? @"YES" : @"NO",
            self.autoPauseEnabled ? @"YES" : @"NO");
    }
    [self pauseAllPlayers];
  } else {
    if (self.playbackPaused) {
      NSLog(@"[Daemon] Resuming because hidden=%@ locked=%@ autoPause=%@",
            wallpaperHidden ? @"YES" : @"NO", screenLocked ? @"YES" : @"NO",
            self.autoPauseEnabled ? @"YES" : @"NO");
    }
    [self resumeAllPlayers];
  }

  [self updatePerformanceModeConsideringVisibility:wallpaperHidden
                                            paused:self.playbackPaused];
}

- (CGRect)targetDisplayBounds {
  if (self.targetScreen)
    return self.targetScreen.frame;

  if (self.targetDisplayID != kCGNullDirectDisplay)
    return CGDisplayBounds(self.targetDisplayID);

  NSScreen *fallback = [NSScreen mainScreen];
  return fallback ? fallback.frame : CGRectZero;
}

- (BOOL)isWallpaperHiddenOnTargetDisplay {
  NSWindow *primaryWindow = _windows.firstObject;
  
  // Check if wallpaper is on inactive space
  if (primaryWindow && !primaryWindow.isOnActiveSpace) {
    return YES;
  }
  
  // Check for fullscreen app on our display - lightweight check
  return [self hasFullscreenAppOnTargetDisplay];
}

- (BOOL)hasFullscreenAppOnTargetDisplay {
  CGRect targetFrame = [self targetDisplayBounds];
  if (CGRectIsEmpty(targetFrame))
    return NO;
  
  pid_t selfPID = getpid();
  
  // Only get on-screen windows at normal layer (layer 0)
  CFArrayRef windows = CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
      kCGNullWindowID);
  
  if (!windows)
    return NO;
  
  BOOL hasFullscreen = NO;
  CFIndex count = CFArrayGetCount(windows);
  
  // Tolerance for fullscreen detection (allow small differences for menu bar, dock)
  CGFloat tolerance = 50.0f;
  
  for (CFIndex i = 0; i < count; ++i) {
    NSDictionary *window =
        (__bridge NSDictionary *)CFArrayGetValueAtIndex(windows, i);
    
    // Skip our own windows
    NSNumber *ownerPID = window[(NSString *)kCGWindowOwnerPID];
    if (ownerPID && ownerPID.intValue == selfPID)
      continue;
    
    // Only check normal layer windows (layer 0)
    NSNumber *layerNumber = window[(NSString *)kCGWindowLayer];
    if (layerNumber && layerNumber.integerValue != 0)
      continue;
    
    // Skip system elements
    NSString *ownerName = window[(NSString *)kCGWindowOwnerName];
    if ([ownerName isEqualToString:@"Dock"] ||
        [ownerName isEqualToString:@"Window Server"] ||
        [ownerName isEqualToString:@"SystemUIServer"] ||
        [ownerName isEqualToString:@"Control Center"] ||
        [ownerName isEqualToString:@"LiveWallpaper"] ||
        [ownerName isEqualToString:@"wallpaperdaemon"]) {
      continue;
    }
    
    NSDictionary *boundsDict = window[(NSString *)kCGWindowBounds];
    if (!boundsDict)
      continue;
    
    CGRect windowBounds = CGRectZero;
    if (!CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)boundsDict, &windowBounds))
      continue;
    
    // Check if window is on our display (significant overlap)
    CGRect intersection = CGRectIntersection(windowBounds, targetFrame);
    if (CGRectIsNull(intersection))
      continue;
    
    // Check if window covers almost entire screen (fullscreen or maximized)
    BOOL isFullWidth = fabs(windowBounds.size.width - targetFrame.size.width) < tolerance;
    BOOL isFullHeight = fabs(windowBounds.size.height - targetFrame.size.height) < tolerance;
    
    if (isFullWidth && isFullHeight) {
      hasFullscreen = YES;
      break;
    }
  }
  
  CFRelease(windows);
  return hasFullscreen;
}

- (BOOL)isRunningOnBatteryPower {
  CFTypeRef info = IOPSCopyPowerSourcesInfo();
  if (!info)
    return NO;

  CFArrayRef sources = IOPSCopyPowerSourcesList(info);
  if (!sources) {
    CFRelease(info);
    return NO;
  }

  BOOL onBattery = NO;
  CFIndex count = CFArrayGetCount(sources);
  static NSString *typeKey = nil;
  static NSString *stateKey = nil;
  static NSString *internalBattery = nil;
  static NSString *batteryPower = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    typeKey = [[NSString alloc] initWithUTF8String:kIOPSTypeKey];
    stateKey = [[NSString alloc] initWithUTF8String:kIOPSPowerSourceStateKey];
    internalBattery =
        [[NSString alloc] initWithUTF8String:kIOPSInternalBatteryType];
    batteryPower = [[NSString alloc] initWithUTF8String:kIOPSBatteryPowerValue];
  });

  for (CFIndex idx = 0; idx < count; ++idx) {
    CFTypeRef source = CFArrayGetValueAtIndex(sources, idx);
    CFDictionaryRef description = IOPSGetPowerSourceDescription(info, source);
    if (!description)
      continue;

    NSDictionary *details = (__bridge NSDictionary *)description;
    NSString *type = details[typeKey];
    NSString *state = details[stateKey];

    if (!type || !state)
      continue;

    if ([type isEqualToString:internalBattery] &&
        [state isEqualToString:batteryPower]) {
      onBattery = YES;
      break;
    }
  }

  CFRelease(sources);
  CFRelease(info);
  return onBattery;
}

- (BOOL)currentLowPowerModeState {
  NSProcessInfo *processInfo = [NSProcessInfo processInfo];
  if ([processInfo respondsToSelector:@selector(isLowPowerModeEnabled)]) {
    return processInfo.isLowPowerModeEnabled;
  }
  return NO;
}

- (void)powerStateDidChange:(NSNotification *)notification {
  self.runningOnBattery = [self isRunningOnBatteryPower];
  self.lowPowerModeEnabled = [self currentLowPowerModeState];
  [self checkAndUpdatePlaybackState];
}

- (void)updatePerformanceMode {
  [self updatePerformanceModeConsideringVisibility:NO
                                            paused:self.playbackPaused];
}

- (void)updatePerformanceModeConsideringVisibility:(BOOL)wallpaperHidden
                                            paused:(BOOL)isPaused {
  // Use cached values updated by powerStateDidChange event
  BOOL battery = self.runningOnBattery;
  BOOL lowPower = self.lowPowerModeEnabled;
  BOOL visibilityReduction = !isPaused && wallpaperHidden;

  BOOL stateChanged = (battery != self.runningOnBattery) ||
                      (lowPower != self.lowPowerModeEnabled) ||
                      (visibilityReduction != self.visibilityReductionActive);

  self.runningOnBattery = battery;
  self.lowPowerModeEnabled = lowPower;
  self.visibilityReductionActive = visibilityReduction;

  BOOL reduce = battery || lowPower || visibilityReduction;

  if (reduce != self.reducedPerformanceMode || stateChanged) {
    self.reducedPerformanceMode = reduce;
    NSLog(@"[Daemon] %@ performance mode (battery=%@, lowPower=%@, hidden=%@)",
          reduce ? @"Entering" : @"Leaving", battery ? @"YES" : @"NO",
          lowPower ? @"YES" : @"NO", visibilityReduction ? @"YES" : @"NO");
    [self applyPerformanceSettings];
  }
}

- (void)applyPerformanceSettings {
  CGRect bounds = [self targetDisplayBounds];
  
  // Max resolution: 2560x1440 in normal mode, lower in reduced mode
  CGSize targetResolution;
  CGFloat downscaleFactor = self.visibilityReductionActive ? 0.5f : 0.75f;

  if (self.reducedPerformanceMode) {
    CGFloat width = MAX(bounds.size.width * downscaleFactor, 640.0f);
    CGFloat height = MAX(bounds.size.height * downscaleFactor, 360.0f);
    targetResolution = CGSizeMake(width, height);
  } else {
    // Normal mode: cap at 2560x1440 for GPU efficiency
    targetResolution = CGSizeMake(MIN(bounds.size.width, 2560.0f), 
                                   MIN(bounds.size.height, 1440.0f));
  }

  self.targetPlaybackRate = self.visibilityReductionActive ? 0.75f : 1.0f;

  double peakBitRate = self.reducedPerformanceMode ? 6e6 : 0.0;
  
  // Always use 1.0 scale - Retina scaling unnecessary for fullscreen wallpaper
  for (AVPlayerLayer *layer in _playerLayers) {
    layer.contentsScale = 1.0f;
  }

  for (AVQueuePlayer *player in _players) {
    AVPlayerItem *item = player.currentItem;
    if (item) {
      item.preferredMaximumResolution = targetResolution;
      item.preferredPeakBitRate = peakBitRate;
    }
  }

  for (AVPlayerLooper *looper in _loopers) {
    for (AVPlayerItem *loopItem in looper.loopingPlayerItems) {
      loopItem.preferredMaximumResolution = targetResolution;
      loopItem.preferredPeakBitRate = peakBitRate;
    }
  }

  [self applyCurrentPlaybackRateToActivePlayers];
}

- (void)applyCurrentPlaybackRateToActivePlayers {
  for (AVQueuePlayer *player in _players) {
    if (player.rate > 0.0f) {
      [player playImmediatelyAtRate:self.targetPlaybackRate];
    }
  }
}
- (BOOL)isScreenLocked {
  CFBooleanRef locked = (CFBooleanRef)CFPreferencesCopyAppValue(
      CFSTR("ScreenLocked"), CFSTR("com.apple.loginwindow"));

  BOOL isLocked = NO;

  if (locked && CFGetTypeID(locked) == CFBooleanGetTypeID()) {
    isLocked = (locked == kCFBooleanTrue);
  }

  if (locked)
    CFRelease(locked);

  return isLocked;
}

- (void)activeApplicationChanged:(NSNotification *)notification {
  if (self.screen_locked)
    return;

  [self checkAndUpdatePlaybackState];
}

- (void)activeSpaceChanged:(NSNotification *)notification {
  if (self.screen_locked)
    return;

  [self checkAndUpdatePlaybackState];
}

- (BOOL)isFrontmostAppAllowed {
  NSRunningApplication *front =
      [[NSWorkspace sharedWorkspace] frontmostApplication];

  if (!front)
    return YES;

  static NSSet<NSString *> *allowedBundleIDs;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    allowedBundleIDs = [NSSet
        setWithArray:@[ @"com.apple.finder", @"com.thusvill.LiveWallpaper" ]];
  });

  return [allowedBundleIDs containsObject:front.bundleIdentifier];
}

- (void)resumeAllPlayers {
  if (_players.count == 0)
    return;

  if (!self.playbackPaused)
    return;

  // Sync to global video time before resuming
  [self syncToGlobalTime];

  for (AVQueuePlayer *player in _players) {
    player.actionAtItemEnd = AVPlayerActionAtItemEndAdvance;
    [player playImmediatelyAtRate:self.targetPlaybackRate];
  }

  CFTimeInterval resumeTime = CACurrentMediaTime();
  for (AVPlayerLayer *layer in _playerLayers) {
    CFTimeInterval pausedTime = layer.timeOffset;
    layer.speed = 1.0f;
    layer.timeOffset = 0.0f;
    CFTimeInterval timeSincePause =
        [layer convertTime:resumeTime fromLayer:nil] - pausedTime;
    layer.beginTime = timeSincePause;
  }

  self.playbackPaused = NO;
  NSLog(@"[Daemon] Resumed playback");
}

- (void)syncToGlobalTime {
  if (_videoStartTime <= 0 || _videoDuration <= 0)
    return;
  
  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  NSTimeInterval elapsed = now - _videoStartTime;
  
  // Calculate position in video (loop)
  NSTimeInterval position = fmod(elapsed, _videoDuration);
  
  CMTime seekTime = CMTimeMakeWithSeconds(position, NSEC_PER_SEC);
  
  for (AVQueuePlayer *player in _players) {
    [player seekToTime:seekTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
  }
  
  NSLog(@"[Daemon] Synced to global time: %.2fs (elapsed: %.2fs, duration: %.2fs)", 
        position, elapsed, _videoDuration);
}

- (void)pauseAllPlayers {
  if (self.playbackPaused)
    return;

  for (AVQueuePlayer *player in _players) {
    [player pause];
  }
  self.playbackPaused = YES;
  NSLog(@"[Daemon] Paused playback");
}

- (void)setAutoPauseEnabled:(BOOL)enabled {
  _autoPauseEnabled = enabled;
  [[NSUserDefaults standardUserDefaults] setBool:enabled
                                          forKey:@"pauseOnAppFocus"];
  [[NSUserDefaults standardUserDefaults] synchronize];

  NSLog(@"[Daemon] Auto-pause %@", enabled ? @"enabled" : @"disabled");

  // // If disabled, ensure playback resumes
  // if (enabled) {
  //   // If enabled, immediately check current state
  //   [self checkAndUpdatePlaybackState];
  // }
  [self checkAndUpdatePlaybackState];
}

- (void)setVolume:(float)volume {
  NSLog(@"[Daemon] setVolume called: %.2f", volume);
  for (AVQueuePlayer *player in _players) {
    player.volume = volume;
  }
  [[NSUserDefaults standardUserDefaults] setFloat:volume
                                           forKey:@"wallpapervolume"];
}

static const double kSecondsBeforeEndToSwitch = 2.0;

- (void)addLoopEndObserverForPlayer:(AVQueuePlayer *)player {
  [self removeLoopEndObserver];
  
  __weak typeof(self) weakSelf = self;
  _didFireEndNotificationThisLoop = NO;
  
  CMTime interval = CMTimeMakeWithSeconds(0.5, NSEC_PER_SEC);
  _loopEndTimeObserver = [player addPeriodicTimeObserverForInterval:interval
                                                              queue:dispatch_get_main_queue()
                                                         usingBlock:^(CMTime time) {
    __strong typeof(weakSelf) self = weakSelf;
    if (!self || self->_players.count == 0) return;
    
    AVPlayerItem *item = player.currentItem;
    if (!item || item.status != AVPlayerItemStatusReadyToPlay) return;
    
    double currentSec = CMTimeGetSeconds(time);
    double durationSec = CMTimeGetSeconds(item.duration);
    if (!isfinite(durationSec) || durationSec < kSecondsBeforeEndToSwitch + 1.0) return;
    
    double switchAtSec = durationSec - kSecondsBeforeEndToSwitch;
    if (currentSec >= switchAtSec && !self->_didFireEndNotificationThisLoop) {
      self->_didFireEndNotificationThisLoop = YES;
      NSLog(@"[Daemon] Video ~%.0fs before end, notifying slideshow manager", kSecondsBeforeEndToSwitch);
      CFNotificationCenterPostNotification(
          CFNotificationCenterGetDarwinNotifyCenter(),
          CFSTR("com.live.wallpaper.videoEnded"), NULL, NULL, true);
    } else if (currentSec < 1.0) {
      self->_didFireEndNotificationThisLoop = NO;
    }
  }];
}

- (void)removeLoopEndObserver {
  if (_loopEndTimeObserver && _players.count > 0) {
    [_players.firstObject removeTimeObserver:_loopEndTimeObserver];
    _loopEndTimeObserver = nil;
  }
}
- (bool)setStaticWallpaper {
  @autoreleasepool {
    if (!_framePath)
      return false;
    if (![[NSFileManager defaultManager] fileExistsAtPath:_framePath])
      return false;
    if (!_targetScreen)
      return false;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger scaleMode = [defaults integerForKey:@"scale_mode"];

    NSImageScaling scaling = NSImageScaleProportionallyUpOrDown;
    BOOL allowClipping = NO;

    switch (scaleMode) {
    case 0:
      scaling = NSImageScaleProportionallyUpOrDown;
      allowClipping = YES;
      break;
    case 1:
      scaling = NSImageScaleProportionallyUpOrDown;
      allowClipping = NO;
      break;
    case 2:
      scaling = NSImageScaleAxesIndependently;
      allowClipping = NO;
      break;
    case 3:
      scaling = NSImageScaleNone;
      allowClipping = NO;
      break;
    case 4:
      scaling = NSImageScaleProportionallyUpOrDown;
      allowClipping = YES;
      break;
    default:
      break;
    }
    NSDictionary *options = @{
      NSWorkspaceDesktopImageScalingKey : @(scaling),
      NSWorkspaceDesktopImageAllowClippingKey : @(allowClipping),
      NSWorkspaceDesktopImageFillColorKey : [NSColor blackColor]
    };

    NSURL *imageURL = [NSURL fileURLWithPath:_framePath];
    NSError *error = nil;

    {
      NSNumber *screenNumber =
          _targetScreen.deviceDescription[@"NSScreenNumber"];
      CGDirectDisplayID did =
          (CGDirectDisplayID)[screenNumber unsignedIntValue];

      // Get display info from IOKit (public API)
      CFDictionaryRef displayInfo = IODisplayCreateInfoDictionary(
          CGDisplayIOServicePort(did), kIOReturnSuccess);

      if (displayInfo) {
        NSDictionary *info = (__bridge NSDictionary *)displayInfo;

        NSString *uuid = info[@"DisplayUUID"];
        if (uuid) {
          // Build the desktop dictionary that macOS uses internally
          NSMutableDictionary *desktopSpec = [NSMutableDictionary dictionary];
          desktopSpec[@"ImageFilePath"] = _framePath;
          desktopSpec[@"ImageFileURL"] = [imageURL absoluteString];
          desktopSpec[@"NewDisplayDictionary"] = @{
            @"desktop-picture-options" : @{
              @"picture-options" : @(scaling),
              @"allow-clipping" : @(allowClipping),
              @"fill-color" : @"0 0 0"
            }
          };

          // Write to com.apple.desktop preferences
          CFPreferencesSetAppValue((__bridge CFStringRef)uuid,
                                   (__bridge CFPropertyListRef)desktopSpec,
                                   CFSTR("com.apple.desktop"));
          CFPreferencesAppSynchronize(CFSTR("com.apple.desktop"));
        }

        CFRelease(displayInfo);
      }
    }

    BOOL success =
        [[NSWorkspace sharedWorkspace] setDesktopImageURL:imageURL
                                                forScreen:_targetScreen
                                                  options:options
                                                    error:&error];

    return success;
  }
}

- (void)transitionToVideo:(NSString *)newVideoPath withImagePath:(NSString *)newImagePath {
  if (_isTransitioning) {
    NSLog(@"[Daemon] Already transitioning, ignoring request");
    return;
  }

  if ([newVideoPath isEqualToString:_currentVideoPath]) {
    NSLog(@"[Daemon] Same video, ignoring transition");
    return;
  }

  if (![[NSFileManager defaultManager] fileExistsAtPath:newVideoPath]) {
    NSLog(@"[Daemon] Video file not found: %@", newVideoPath);
    return;
  }

  _isTransitioning = YES;
  NSLog(@"[Daemon] Starting crossfade transition to: %@", newVideoPath);
  
  // Reset start time for new video (first daemon to transition sets the time)
  NSString *startTimeKey = [NSString stringWithFormat:@"VideoStartTime_%@", 
      [[newVideoPath lastPathComponent] stringByDeletingPathExtension]];
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  _videoStartTime = [NSDate timeIntervalSinceReferenceDate];
  [defaults setDouble:_videoStartTime forKey:startTimeKey];
  [defaults synchronize];
  
  // Get new video duration
  NSURL *newVideoURL = [NSURL fileURLWithPath:newVideoPath];
  AVAsset *newAsset = [AVAsset assetWithURL:newVideoURL];
  _videoDuration = CMTimeGetSeconds(newAsset.duration);
  if (_videoDuration <= 0) {
    _videoDuration = 60.0; // Fallback
  }

  // Update frame path for static wallpaper
  if (newImagePath && newImagePath.length > 0) {
    _framePath = newImagePath;
  }

  // Create new player and layer
  NSURL *videoURL = [NSURL fileURLWithPath:newVideoPath];
  AVPlayerItem *newItem = [[AVPlayerItem alloc] initWithURL:videoURL];
  AVQueuePlayer *newPlayer = [AVQueuePlayer queuePlayerWithItems:@[]];
  AVPlayerLooper *newLooper = [AVPlayerLooper playerLooperWithPlayer:newPlayer
                                                        templateItem:newItem];

  AVPlayerLayer *newLayer = [AVPlayerLayer playerLayerWithPlayer:newPlayer];

  // Configure layer with same settings as original
  NSInteger scaleMode = [defaults integerForKey:@"scale_mode"];

  switch (scaleMode) {
    case 1:
      newLayer.videoGravity = AVLayerVideoGravityResizeAspect;
      break;
    case 2:
      newLayer.videoGravity = AVLayerVideoGravityResize;
      break;
    case 3:
      newLayer.videoGravity = AVLayerVideoGravityResizeAspect;
      break;
    case 0:
    case 4:
    default:
      newLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
      break;
  }

  NSWindow *window = _windows.firstObject;
  if (!window) {
    NSLog(@"[Daemon] No window available for transition");
    _isTransitioning = NO;
    return;
  }

  newLayer.frame = window.contentView.bounds;
  newLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
  newLayer.drawsAsynchronously = YES;
  newLayer.contentsScale = 1.0f;
  newLayer.needsDisplayOnBoundsChange = NO;
  newLayer.actions = @{@"contents" : [NSNull null]};

  // Disable implicit animations for initial setup
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  newLayer.opacity = 0.0f;
  newLayer.transform = CATransform3DMakeScale(1.15f, 1.15f, 1.0f);  // Start scaled up (115%)
  [window.contentView.layer addSublayer:newLayer];
  [CATransaction commit];

  // Configure new player
  newPlayer.volume = [[NSUserDefaults standardUserDefaults] floatForKey:@"wallpapervolume"];
  CGFloat maxWidth = MIN(_targetScreen.frame.size.width, 2560.0f);
  CGFloat maxHeight = MIN(_targetScreen.frame.size.height, 1440.0f);
  newPlayer.currentItem.preferredMaximumResolution = CGSizeMake(maxWidth, maxHeight);
  newPlayer.currentItem.preferredForwardBufferDuration = 2.0;

  // Keep references for the block
  AVPlayerLayer *oldLayer = _playerLayers.firstObject;
  AVQueuePlayer *oldPlayer = _players.firstObject;
  AVPlayerLooper *oldLooper = _loopers.firstObject;

  // Start playback immediately
  [newPlayer play];

  // Wait a moment for video to buffer, then perform crossfade
  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) return;

    NSLog(@"[Daemon] Starting crossfade animation with scale");

    // easeOutCubic timing function
    CAMediaTimingFunction *easeOutCubic = [[CAMediaTimingFunction alloc] initWithControlPoints:0.215 :0.61 :0.355 :1.0];

    // Create fade animations
    CABasicAnimation *fadeIn = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fadeIn.fromValue = @0.0f;
    fadeIn.toValue = @1.0f;
    fadeIn.duration = kCrossfadeDuration;
    fadeIn.timingFunction = easeOutCubic;

    CABasicAnimation *fadeOut = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fadeOut.fromValue = @1.0f;
    fadeOut.toValue = @0.0f;
    fadeOut.duration = kCrossfadeDuration;
    fadeOut.timingFunction = easeOutCubic;

    // Create scale animations - new video: 1.15 -> 1.05, old video: 1.05 -> 0.95
    CABasicAnimation *scaleIn = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scaleIn.fromValue = @1.15f;
    scaleIn.toValue = @1.05f;
    scaleIn.duration = kCrossfadeDuration;
    scaleIn.timingFunction = easeOutCubic;

    CABasicAnimation *scaleOut = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scaleOut.fromValue = @1.05f;
    scaleOut.toValue = @0.95f;
    scaleOut.duration = kCrossfadeDuration;
    scaleOut.timingFunction = easeOutCubic;

    // Group animations for new layer
    CAAnimationGroup *newLayerAnimations = [CAAnimationGroup animation];
    newLayerAnimations.animations = @[fadeIn, scaleIn];
    newLayerAnimations.duration = kCrossfadeDuration;
    newLayerAnimations.fillMode = kCAFillModeForwards;
    newLayerAnimations.removedOnCompletion = NO;

    // Group animations for old layer
    CAAnimationGroup *oldLayerAnimations = [CAAnimationGroup animation];
    oldLayerAnimations.animations = @[fadeOut, scaleOut];
    oldLayerAnimations.duration = kCrossfadeDuration;
    oldLayerAnimations.fillMode = kCAFillModeForwards;
    oldLayerAnimations.removedOnCompletion = NO;

    // Add animations
    [newLayer addAnimation:newLayerAnimations forKey:@"transitionIn"];
    if (oldLayer) {
      [oldLayer addAnimation:oldLayerAnimations forKey:@"transitionOut"];
    }

    // Set final model values (without animation) - base scale is 105%
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    newLayer.opacity = 1.0f;
    newLayer.transform = CATransform3DMakeScale(1.05f, 1.05f, 1.0f);
    if (oldLayer) {
      oldLayer.opacity = 0.0f;
      oldLayer.transform = CATransform3DMakeScale(0.95f, 0.95f, 1.0f);
    }
    [CATransaction commit];

    // Cleanup after animation completes
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCrossfadeDuration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      __strong typeof(weakSelf) strongSelf2 = weakSelf;
      if (!strongSelf2) return;

      NSWindow *win = strongSelf2->_windows.firstObject;
      CALayer *contentLayer = win.contentView.layer;

      // Remove loop observer from OLD player before we change _players
      [strongSelf2 removeLoopEndObserver];

      // Remove old layer first
      if (oldLayer) {
        [oldLayer removeAnimationForKey:@"transitionOut"];
        [oldLayer removeFromSuperlayer];
      }
      [oldPlayer pause];

      // Remove new layer's animation and fix final state in one transaction
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      [newLayer removeAnimationForKey:@"transitionIn"];
      newLayer.opacity = 1.0f;
      newLayer.transform = CATransform3DMakeScale(1.05f, 1.05f, 1.0f);
      newLayer.hidden = NO;
      [CATransaction commit];

      // Ensure new layer is on top (remove and re-add so it's the only/front sublayer)
      [newLayer removeFromSuperlayer];
      [contentLayer addSublayer:newLayer];

      // Update arrays
      [strongSelf2->_players removeObject:oldPlayer];
      [strongSelf2->_playerLayers removeObject:oldLayer];
      [strongSelf2->_loopers removeObject:oldLooper];

      [strongSelf2->_players addObject:newPlayer];
      [strongSelf2->_playerLayers addObject:newLayer];
      [strongSelf2->_loopers addObject:newLooper];

      strongSelf2->_currentVideoPath = newVideoPath;
      strongSelf2->_isTransitioning = NO;

      [strongSelf2 addLoopEndObserverForPlayer:newPlayer];

      [win orderFront:nil];

      NSLog(@"[Daemon] Crossfade transition completed");
    });
  });
}

@end

static void VolumeChangedCallback(CFNotificationCenterRef center,
                                  void *observer, CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
  VideoWallpaperDaemon *daemon = (__bridge VideoWallpaperDaemon *)observer;
  float volume =
      [[NSUserDefaults standardUserDefaults] floatForKey:@"wallpapervolume"];
  [daemon setVolume:volume];
}

static void SpaceChangeCallback(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object,
                                CFDictionaryRef userInfo) {
  VideoWallpaperDaemon *daemon = (__bridge VideoWallpaperDaemon *)observer;
  if ([daemon setStaticWallpaper]) {
    NSLog(@"Wallpaper applied successfully!");
  }
}

static void AutoPauseChangedCallback(CFNotificationCenterRef center,
                                     void *observer, CFStringRef name,
                                     const void *object,
                                     CFDictionaryRef userInfo) {
  VideoWallpaperDaemon *daemon = (__bridge VideoWallpaperDaemon *)observer;
  BOOL enabled =
      [[NSUserDefaults standardUserDefaults] boolForKey:@"pauseOnAppFocus"];
  [daemon setAutoPauseEnabled:enabled];
}

static void VideoChangeCallback(CFNotificationCenterRef center,
                                void *observer, CFStringRef name,
                                const void *object,
                                CFDictionaryRef userInfo) {
  VideoWallpaperDaemon *daemon = (__bridge VideoWallpaperDaemon *)observer;

  // Read new video path from UserDefaults (set by WallpaperEngine before posting notification)
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults synchronize];

  CGDirectDisplayID targetDisplayID = daemon.targetDisplayID;
  NSString *key = [NSString stringWithFormat:@"TransitionVideo_%u", targetDisplayID];
  NSString *imageKey = [NSString stringWithFormat:@"TransitionImage_%u", targetDisplayID];

  NSString *newVideoPath = [defaults stringForKey:key];
  NSString *newImagePath = [defaults stringForKey:imageKey];

  if (newVideoPath && newVideoPath.length > 0) {
    NSLog(@"[Daemon] Received video change notification for display %u: %@", targetDisplayID, newVideoPath);
    [daemon transitionToVideo:newVideoPath withImagePath:newImagePath];

    // Clear the transition keys
    [defaults removeObjectForKey:key];
    [defaults removeObjectForKey:imageKey];
    [defaults synchronize];
  }
}

NSScreen *ScreenForDisplayID(CGDirectDisplayID displayID) {
  for (NSScreen *screen in [NSScreen screens]) {
    NSDictionary *screenDict = [screen deviceDescription];
    NSNumber *screenNumber = [screenDict objectForKey:@"NSScreenNumber"];
    if (screenNumber && [screenNumber unsignedIntValue] == displayID) {
      return screen;
    }
  }
  return nil;
}

float volume;
int main(int argc, const char *argv[]) {

  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    [NSApp finishLaunching];

    if (argc < 4) {
      NSLog(@"Usage: %s <video.mp4> <frame_output.png> <volume> <scale_mode> "
            @"<display_id(optional)>",
            argv[0]);
      return 1;
    }

    NSString *videoPath = [NSString stringWithUTF8String:argv[1]];
    NSString *framePath = [NSString stringWithUTF8String:argv[2]];
    NSInteger scaleMode = (NSInteger)strtol(argv[4], NULL, 10);
    NSScreen *targetScreen = [NSScreen mainScreen];
    if (argc >= 6) {
      NSString *displayIDStr = [NSString stringWithUTF8String:argv[5]];
      CGDirectDisplayID displayID = (CGDirectDisplayID)[displayIDStr intValue];
      targetScreen = ScreenForDisplayID(displayID);
      if (targetScreen) {
        NSLog(@"Targeting display ID %u on screen %@", displayID, targetScreen);
      } else {
        NSLog(@"Warning: No screen found for display ID %u. Using all screens.",
              displayID);
      }
    }
    volume = atof(argv[3]);
    [[NSUserDefaults standardUserDefaults] setFloat:volume
                                             forKey:@"wallpapervolume"];

    VideoWallpaperDaemon *daemon =
        [[VideoWallpaperDaemon alloc] initWithVideo:videoPath
                                        frameOutput:framePath
                                        scalingMode:scaleMode
                                       targetScreen:targetScreen];

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(daemon), VolumeChangedCallback,
        CFSTR("com.live.wallpaper.volumeChanged"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(daemon), AutoPauseChangedCallback,
        CFSTR("com.live.wallpaper.autoPauseChanged"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(daemon), SpaceChangeCallback,
        CFSTR("com.live.wallpaper.spaceChanged"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(daemon), VideoChangeCallback,
        CFSTR("com.live.wallpaper.videoChanged"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)daemon, terminateWallpaperDaemonCallback,
        CFSTR("com.live.wallpaper.terminate"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    [[NSRunLoop mainRunLoop] run];
  }

  return 0;
}
