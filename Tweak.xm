// LiquidGlassNC — recreates an iOS 26 style "Liquid Glass" look for the
// pre-26 Notification Center / Cover Sheet on jailbroken devices.
//
// IMPORTANT: SpringBoard's private class names for the notification shade
// change between iOS versions (e.g. SBDashBoardViewController,
// CSCoverSheetViewController, CSCoverSheetView on 14–17). You will likely
// need to adjust the %hook target class names below to match the iOS
// version you're building for. Use a class-dump / header dump of the
// installed SpringBoard to confirm the right class + the view that hosts
// the shade's background.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

// ---------------------------------------------------------------------
// Minimal stub interfaces for SpringBoard's private classes.
//
// We don't have Apple's real private headers for these, so the compiler
// only knows about them as opaque forward-declared types unless we tell
// it what they inherit from. Declaring them here as plain UIView /
// UIViewController subclasses is enough for %hook, %property, and
// %orig to work correctly — we're not redefining Apple's real class,
// just describing its public shape (superclass) so Logos can generate
// valid code against it.
//
// Adjust the superclass/name here to match whatever class you found
// via class-dump for your target iOS version.
// ---------------------------------------------------------------------
@interface CSCoverSheetView : UIView
@end

@interface CSCoverSheetViewController : UIViewController
@end

// ---------------------------------------------------------------------
// Helper: builds the "glass" layer stack — blur, vibrancy tint,
// a moving specular highlight, and a continuous-corner mask.
// ---------------------------------------------------------------------
@interface LGGlassView : UIVisualEffectView
@property (nonatomic, strong) CAGradientLayer *specularLayer;
@end

@implementation LGGlassView

- (instancetype)initWithFrame:(CGRect)frame {
	UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
	self = [super initWithEffect:blur];
	if (self) {
		self.frame = frame;
		self.layer.cornerCurve = kCACornerCurveContinuous;
		self.layer.cornerRadius = 44.0;
		self.clipsToBounds = YES;
		self.layer.masksToBounds = YES;

		UIView *tint = [[UIView alloc] initWithFrame:self.bounds];
		tint.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
		tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[self.contentView addSubview:tint];

		CAGradientLayer *spec = [CAGradientLayer layer];
		spec.frame = self.bounds;
		spec.colors = @[
			(id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
			(id)[UIColor colorWithWhite:1.0 alpha:0.22].CGColor,
			(id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor
		];
		spec.locations = @[@0.35, @0.5, @0.65];
		spec.startPoint = CGPointMake(0.0, 0.0);
		spec.endPoint = CGPointMake(1.0, 1.0);
		[self.contentView.layer addSublayer:spec];
		self.specularLayer = spec;

		[self animateSpecularSweep];
	}
	return self;
}

- (void)animateSpecularSweep {
	CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"locations"];
	anim.fromValue = @[@-0.2, @-0.05, @0.1];
	anim.toValue = @[@0.9, @1.05, @1.2];
	anim.duration = 6.0;
	anim.autoreverses = YES;
	anim.repeatCount = HUGE_VALF;
	anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
	[self.specularLayer addAnimation:anim forKey:@"sweep"];
}

- (void)updateForPullProgress:(CGFloat)progress {
	progress = MAX(0.0, MIN(1.0, progress));
	self.layer.cornerRadius = 44.0 + (progress * 10.0);
	self.specularLayer.opacity = 0.6 + (progress * 0.4);
}

@end

// ---------------------------------------------------------------------
// Hook: inject the glass view behind the notification shade's content,
// and drive updateForPullProgress: from the shade's own pan gesture.
//
// Replace `CSCoverSheetView` / `_backgroundView` below with the actual
// class + ivar/property names you find in your target iOS version.
// ---------------------------------------------------------------------
%hook CSCoverSheetView

%property (nonatomic, strong) LGGlassView *lg_glassView;

- (void)didMoveToWindow {
	%orig;
	if (self.window && !self.lg_glassView) {
		LGGlassView *glass = [[LGGlassView alloc] initWithFrame:self.bounds];
		glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[self insertSubview:glass atIndex:0];
		self.lg_glassView = glass;
	}
}

- (void)layoutSubviews {
	%orig;
	self.lg_glassView.frame = self.bounds;
}

%end

// Drive the stretch effect from the shade's pan gesture recognizer.
// SBDashBoardViewController (or its 17+ equivalent) typically owns the
// gesture; hook wherever the "percent revealed" value is computed.
%hook CSCoverSheetViewController

- (void)_updateRevealPercent:(CGFloat)percent {
	%orig;
	UIView *root = [self valueForKey:@"view"];
	for (UIView *sub in root.subviews) {
		if ([sub isKindOfClass:%c(CSCoverSheetView)]) {
			LGGlassView *glass = [sub valueForKey:@"lg_glassView"];
			[glass updateForPullProgress:percent];
		}
	}
}

%end

%ctor {
	%init;
}
