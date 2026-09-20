#import "AttributedBodyBridge.h"

NSAttributedString * _Nullable RelayDecodeLegacyAttributedBody(NSData *data) {
    // This contains malformed Messages data. It does not make NSUnarchiver safe for untrusted input.
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        id decoded = [NSUnarchiver unarchiveObjectWithData:data];
#pragma clang diagnostic pop
        if (![decoded isKindOfClass:[NSAttributedString class]]) {
            return nil;
        }
        return (NSAttributedString *)decoded;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}
