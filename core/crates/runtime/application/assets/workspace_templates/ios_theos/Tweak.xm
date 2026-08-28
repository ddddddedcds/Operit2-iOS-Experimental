#import <UIKit/UIKit.h>

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"MyTweak"
                         message:@"Loaded!"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [[UIApplication sharedApplication].keyWindow.rootViewController
        presentViewController:alert
                     animated:YES
                   completion:nil];
}

%end
