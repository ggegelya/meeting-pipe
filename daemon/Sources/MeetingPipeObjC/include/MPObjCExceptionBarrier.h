#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Run `body`, catching an Objective-C `NSException` raised out of it.
///
/// REC12 item 2. This target exists for this one function. `AVAudioNode.installTap`
/// reports failure by **raising an `NSException`**, and Swift has no construct that
/// catches one: there is no `try` that helps and no `catch` that runs, so
/// `objc_terminate` calls `abort()`. All four MeetingPipe crash reports on the owner's
/// machine are that abort. Only Objective-C's `@try` / `@catch` can stand between the
/// raise and the process, and SwiftPM has no mixed Objective-C / Swift target, which is
/// why this is a leaf target of its own rather than a file beside its caller.
///
/// Returns `nil` when `body` returned normally, otherwise the exception's name and
/// `reason` joined. That `reason` string is the one thing no crash report carries
/// (`asi` holds only "abort() called"), which is why all four aborts ended with the
/// raise condition inferred from the call site rather than read.
///
/// **A catch here is terminal for whatever `body` was touching, and that is a
/// correctness rule rather than a style note.** The raise unwinds through Swift frames
/// the compiler emitted as non-unwinding, so their cleanups do not run, and it unwinds
/// out of AVFAudio's own C++ internals part-way through whatever they were doing.
/// Nothing about the object `body` touched is defined afterwards, so a caller must
/// retire it rather than try again. `GuardedTapInstall` is the only caller and makes
/// that mechanical: a caught raise condemns the engine, and the seam then refuses to
/// hand that engine another tap for as long as it exists.
///
/// Limit worth stating rather than papering over: this catches `NSException` and only
/// `NSException`. Objective-C can `@throw` any object, but the vehicle here is
/// `+[NSException raise:format:]`, which is in the backtrace of every one of the four
/// reports, and a catch-all for a raise nobody has observed would be machinery the
/// evidence does not contain.
///
/// `body` does not escape, so a Swift caller passes a non-escaping closure straight
/// through.
NSString *_Nullable MPRunCatchingObjCException(void (NS_NOESCAPE ^body)(void));

NS_ASSUME_NONNULL_END
