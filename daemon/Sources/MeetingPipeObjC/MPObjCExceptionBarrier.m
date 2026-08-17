#import "MPObjCExceptionBarrier.h"

NSString *_Nullable MPRunCatchingObjCException(void (NS_NOESCAPE ^body)(void)) {
    @try {
        body();
    } @catch (NSException *exception) {
        // `reason` is the whole diagnostic value of this function, and it is optional on
        // NSException, so say so rather than returning a bare name that reads like a
        // truncated string.
        NSString *reason = exception.reason ?: @"(no reason given)";
        return [NSString stringWithFormat:@"%@: %@", exception.name, reason];
    }
    return nil;
}
