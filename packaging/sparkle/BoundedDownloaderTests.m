// Compile the actual patched downloader; cache operations are forbidden in these
// temporary-feed tests. No installation, external network or signing keys.
#import <Foundation/Foundation.h>
#import "SPUDownloader.m"
NSString *const SUSparkleErrorDomain = @"SparkleTest";
@implementation SPULocalCacheDirectory
+ (NSString *)cachePathForBundleIdentifier:(NSString *)identifier { abort(); }
+ (void)removeOldItemsInDirectory:(NSString *)directory { abort(); }
+ (NSString *)createUniqueDirectoryInDirectory:(NSString *)directory { abort(); }
@end

@interface Probe : NSObject <SPUDownloaderDelegate>
@property BOOL done;
@property BOOL failed;
@property NSUInteger length;
@end
@implementation Probe
- (void)downloaderDidSetDownloadBookmarkData:(NSData *)data downloadToken:(NSString *)token { abort(); }
- (void)downloaderDidReceiveExpectedContentLength:(int64_t)length {}
- (void)downloaderDidReceiveDataOfLength:(uint64_t)length {}
- (void)downloaderDidFinishWithTemporaryDownloadData:(SPUDownloadData *)data { self.done=YES; self.length=data.data.length; }
- (void)downloaderDidFailWithError:(NSError *)error { self.done=YES; self.failed=YES; NSLog(@"expected test failure: %@", error); }
@end
static void pump(BOOL (^finished)(void)) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:40];
  while (!finished() && deadline.timeIntervalSinceNow > 0) {
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
  assert(finished());
}
int main(void) { @autoreleasepool {
  NSString *base = NSProcessInfo.processInfo.environment[@"BOUNDS_TEST_URL"];
  assert(base != nil);
  for (NSString *path in @[@"/exact", @"/oversize", @"/redirect", @"/deadline"]) {
    Probe *probe=[Probe new]; SPUDownloader *downloader=[[SPUDownloader alloc] initWithDelegate:probe];
    [downloader startTemporaryDownloadWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:path]]]];
    pump(^BOOL { return probe.done; });
    NSLog(@"path %@ failed %d length %lu", path, probe.failed, (unsigned long)probe.length);
    assert(probe.failed == ![path isEqualToString:@"/exact"]);
    if (!probe.failed) { assert(probe.length == 1048576); }
  }
  Probe *probe=[Probe new]; SPUDownloader *downloader=[[SPUDownloader alloc] initWithDelegate:probe];
  [downloader startTemporaryDownloadWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/stall"]]]];
  pump(^BOOL { return [downloader valueForKey:@"_downloadSession"] != nil; });
  NSURLSession *session=[downloader valueForKey:@"_downloadSession"];
  assert(session.configuration.timeoutIntervalForResource == 30);
  __block BOOL cleaned=NO; [downloader cleanup:^{ cleaned=YES; }]; pump(^BOOL { return cleaned; });
  probe=[Probe new]; downloader=[[SPUDownloader alloc] initWithDelegate:probe];
  [downloader startPersistentDownloadWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/stall"]]] bundleIdentifier:@"test" desiredFilename:@"test.zip"];
  SPUDownloader *persistent=downloader;
  pump(^BOOL { return [persistent valueForKey:@"_downloadSession"] != nil; });
  session=[downloader valueForKey:@"_downloadSession"];
  assert(session.configuration.timeoutIntervalForResource == 1800);
  [downloader URLSession:session downloadTask:nil didWriteData:1 totalBytesWritten:4294967297LL totalBytesExpectedToWrite:-1];
  assert([downloader valueForKey:@"_boundsError"] != nil);
  cleaned=NO; [downloader cleanup:^{ cleaned=YES; }]; pump(^BOOL { return cleaned; });
  puts("PASS: exact feed cap, chunked overflow rejection, check/download deadlines, cancellation, archive overflow cancellation");
} return 0; }
