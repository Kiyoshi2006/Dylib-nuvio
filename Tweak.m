#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void (*orig_layoutSubviews)(UITabBar *, SEL);
static void (*orig_setHidden)(UITabBar *, SEL, BOOL);

static void hideView(UIView *v) {
    if ([v isKindOfClass:[UITabBar class]] && orig_setHidden) {
        orig_setHidden((UITabBar *)v, @selector(setHidden:), YES);
    } else {
        v.hidden = YES;
    }
    v.alpha = 0;
    v.userInteractionEnabled = NO;
}

static void new_layoutSubviews(UITabBar *self, SEL _cmd) {
    if (orig_layoutSubviews) orig_layoutSubviews(self, _cmd);
    hideView(self);
}

static void new_setHidden(UITabBar *self, SEL _cmd, BOOL hidden) {
    hideView(self);
}

static IMP hookMethod(Class cls, SEL sel, IMP newImp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    IMP orig = method_getImplementation(m);
    if (!class_addMethod(cls, sel, newImp, method_getTypeEncoding(m))) {
        orig = method_setImplementation(m, newImp);
    }
    return orig;
}

static void collect(UIView *v, NSMutableArray *out) {
    NSString *n = NSStringFromClass([v class]);
    if ([v isKindOfClass:[UITabBar class]] || [n containsString:@"TabBar"]) {
        [out addObject:v];
    }
    for (UIView *s in v.subviews) collect(s, out);
}

static NSArray<UIWindow *> *allWindows(void) {
    NSMutableArray *ws = [NSMutableArray array];
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            [ws addObjectsFromArray:((UIWindowScene *)s).windows];
        }
    }
    return ws;
}

static NSArray<UIView *> *findBars(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (UIWindow *w in allWindows()) collect(w, out);
    return out;
}

static void sweep(void) {
    for (UIView *v in findBars()) hideView(v);
}

static void showAlert(void) {
    NSArray *bars = findBars();
    NSMutableArray *names = [NSMutableArray array];
    for (UIView *v in bars) [names addObject:NSStringFromClass([v class])];
    NSString *msg = [NSString stringWithFormat:@"Đã nạp. Tìm thấy %lu view TabBar: %@",
                     (unsigned long)bars.count, [names componentsJoinedByString:@", "]];

    UIWindow *win = nil;
    for (UIWindow *w in allWindows()) { if (w.isKeyWindow) win = w; }
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if (!vc) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"NuvioHideTabBar v3"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}

__attribute__((constructor)) static void NuvioHideTabBarInit(void) {
    orig_layoutSubviews = (void *)hookMethod([UITabBar class], @selector(layoutSubviews), (IMP)new_layoutSubviews);
    orig_setHidden = (void *)hookMethod([UITabBar class], @selector(setHidden:), (IMP)new_setHidden);

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) { sweep(); }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ showAlert(); });
    });
}
