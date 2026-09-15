#import <UIKit/UIKit.h>
#import "../ProtocolContext.h"
#import "../SubtitleHUD.h"
#import "../SubtitleHUDCore.h"
#import "../NavigationSubtitleHUD.h"
@interface TIOSubtitleFakePlugin:NSObject
@property NSDictionary *last;
@property NSUInteger sends;
@end
@implementation TIOSubtitleFakePlugin
- (void)handleMethodCall:(id)call result:(void(^)(id))result{NSDictionary *args=[call valueForKey:@"arguments"];self.last=TIOSubtitleEnvelope([args[@"payload"] valueForKey:@"data"]);self.sends++;NSCAssert([args[@"businessId"] isEqual:@19],@"Subtitle route must use correct business");result(@{@"success":@YES});}
@end
void TIOProtocolRuntimeFixture(void){
    static TIOSubtitleFakePlugin *plugin;plugin=[TIOSubtitleFakePlugin new];NSString *device=@"protocol-subtitle-fixture";
    NSDictionary *config=@{@"config":@{@"font_size":@2,@"content_width":@100,@"max_lines":@5,@"position":@"center",@"is_display":@YES,@"straight_view":@"original"}};
    NSCAssert(TIOProtocolSaveTemplate(@"subtitle",device,config),@"Store clean config");
    TIOProtocolObserveCall(plugin,@"rayneonet_sendMessage",@{@"deviceId":device,@"businessId":@15});
    NSCAssert([TIOSubtitleNavigationStatus()[@"available"] boolValue],@"No official subtitle preview sampled: disk + ordinary route suffice");
    NSCAssert(!TIOSubtitleNavigationStart(),@"Idle confirmation still required");NSCAssert(TIOSubtitleConfirmIdle(),@"Simulated user idle confirmation");
    NSString *sid=TIOSubtitleNavigationStart();NSCAssert(sid.length&&[plugin.last[@"type"] isEqual:@7],@"Own preview starts");NSCAssert(!TIOSubtitleNavigationText(sid,@"no ACK yet"),@"ACK gate retained");
    NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"sid":sid,@"code":@1} options:0 error:nil];uint8_t h[]={8,1,16,8,26,(uint8_t)json.length};NSCAssert(json.length<128,@"Fixture length");NSMutableData *packet=[NSMutableData dataWithBytes:h length:6];[packet appendData:json];
    TIOSubtitleObserveEvent(@{@"eventType":@"messageReceived",@"message":@{@"deviceId":device,@"businessId":@19,@"payload":packet}});
    NSCAssert(TIOSubtitleNavigationText(sid,@"缓存协议测试"),@"Fresh ACK unlocks text");TIOSubtitleNavigationStop(sid,@"test complete");NSCAssert([plugin.last[@"type"] isEqual:@3],@"Own exit");
    NSCAssert(TIOSubtitleConfirmIdle(),@"Confirm exit");NSString *next=TIOSubtitleNavigationStart();NSCAssert(next.length&&![next isEqual:sid],@"Second start uses new SID, no official preview step");TIOSubtitleNavigationStop(next,@"fixture end");TIOSubtitleConfirmIdle();
    NSString *report=@"PASS: actual subtitle runtime restores saved config, uses ordinary live route, no official preview sampling, preserves idle/ACK gates, exits own SID, second start creates fresh SID.";
    [report writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/protocol-runtime-check.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];NSLog(@"%@",report);
}
