// NuvioHideTabBar - luôn ẩn UITabBar native (thanh có nhãn) trong Nuvio.
// Không phụ thuộc Substrate/ElleKit: chỉ dùng ObjC runtime, hợp với TrollFools.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void (*orig_layoutSubviews)(UITabBar *, SEL);
static void (*orig_setHidden)(UITabBar *, SEL, BOOL);

static void new_layoutSubviews(UITabBar *self, SEL _cmd) {
    orig_layoutSubviews(self, _cmd);
    if (!self.isHidden) {
        orig_setHidden(self, @selector(setHidden:), YES);
    }
}

static void new_setHidden(UITabBar *self, SEL _cmd, BOOL hidden) {
    // SwiftUI có thể đòi hiện lại thanh này, bỏ qua và luôn ẩn.
    orig_setHidden(self, _cmd, YES);
}

// Hook chỉ trên UITabBar, không đụng tới UIView toàn cục.
static IMP hookMethod(Class cls, SEL sel, IMP newImp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    IMP orig = method_getImplementation(m);
    if (!class_addMethod(cls, sel, newImp, method_getTypeEncoding(m))) {
        // UITabBar tự định nghĩa method này, thay thẳng.
        orig = method_setImplementation(m, newImp);
    }
    return orig;
}

__attribute__((constructor)) static void NuvioHideTabBarInit(void) {
    Class cls = [UITabBar class];
    orig_layoutSubviews = (void *)hookMethod(cls, @selector(layoutSubviews), (IMP)new_layoutSubviews);
    orig_setHidden = (void *)hookMethod(cls, @selector(setHidden:), (IMP)new_setHidden);
}
