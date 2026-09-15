#import <UIKit/UIKit.h>
#import "../NavigationTransport.h"
#import "../NavigationCore.h"
#import "../A2UIProbe.h"
// Simulator-only stand-ins; never linked into the private official app.
@interface FlutterStandardTypedData:NSObject
@property NSData *data;
+ (instancetype)typedDataWithBytes:(NSData *)data;
@end
@implementation FlutterStandardTypedData
+ (instancetype)typedDataWithBytes:(NSData *)data{FlutterStandardTypedData *v=[self new];v.data=data;return v;}
@end
@interface FlutterMethodCall:NSObject
@property NSString *method;
@property NSDictionary *arguments;
+ (instancetype)methodCallWithMethodName:(NSString *)method arguments:(NSDictionary *)arguments;
@end
@implementation FlutterMethodCall
+ (instancetype)methodCallWithMethodName:(NSString *)method arguments:(NSDictionary *)arguments{FlutterMethodCall *c=[self new];c.method=method;c.arguments=arguments;return c;}
@end
@interface TIONavFakePlugin:NSObject
@property NSDictionary *last;
@property NSUInteger sends;
@property NSNumber *business;
@end
@implementation TIONavFakePlugin
- (void)handleMethodCall:(FlutterMethodCall *)call result:(void(^)(id))result{self.business=call.arguments[@"businessId"];self.last=TIOA2UIDecode([(FlutterStandardTypedData *)call.arguments[@"payload"] data]);self.sends++;result(@{@"success":@YES});}
@end
static NSDictionary *Event(NSString *device,uint32_t seq,NSDictionary *json){return @{@"eventType":@"messageReceived",@"message":@{@"businessId":@15,@"deviceId":device,@"payload":TIOA2UIPacket(19,seq,json)}};}
void TIONavRunTransportFixture(void){
    NSCAssert(UIApplication.sharedApplication.applicationState==UIApplicationStateActive,@"Foreground test");
    static TIONavFakePlugin *p;p=[TIONavFakePlugin new];NSString *device=@"fixture-navigation-not-real-device";
    TIONavObserveCall(p,@"rayneonet_sendMessage",@{@"businessId":@15,@"deviceId":device,@"payload":TIOA2UIPacket(18,123,@{@"cmd":@"dashboard_config"})});
    TIONavEnableDisplay(YES);NSCAssert(![TIONavTransportStatus()[@"enabled"] boolValue],@"No write without baseline");
    TIONavRefreshConnection();NSCAssert(p.sends==1,@"Query once");uint32_t seq=[p.last[@"sequence"] unsignedIntValue];
    NSDictionary *baseline=@{@"cmd":@"dashboard_config",@"payload":@{@"data":@{@"widgets_v2":@[]}}};
    TIONavObserveEvent(Event(@"wrong-device",seq,baseline));NSCAssert([TIONavTransportStatus()[@"pending"] boolValue],@"Wrong device ignored");
    TIONavObserveEvent(Event(device,seq,baseline));NSCAssert(![TIONavTransportStatus()[@"pending"] boolValue],@"Matching baseline");
    TIONavEnableDisplay(YES);TIONavOfferDisplay(TIONavDisplay(@"navigating",2,@"测试道路",120,800,600,YES));TIONavPump();NSCAssert(p.sends==2,@"One frame");seq=[p.last[@"sequence"] unsignedIntValue];
    TIONavObserveEvent(Event(device,seq+1,@{@"code":@0}));NSCAssert([TIONavTransportStatus()[@"pending"] boolValue],@"Wrong ACK ignored");TIONavPump();NSCAssert(p.sends==2,@"No concurrent writes");
    TIONavObserveEvent(Event(device,seq,@{@"code":@0}));TIONavEnableDisplay(NO);NSCAssert([p.last[@"json"][@"cmd"] isEqual:@"widget_uninstall"],@"Explicit stop removes only owned card");
    NSString *owned=p.last[@"json"][@"payload"][@"data"][@"id"];NSCAssert([owned hasPrefix:@"turbo_ui_nav_"],@"Own prefix");
    TIONavObserveEvent(Event(device,[p.last[@"sequence"] unsignedIntValue],@{@"code":@0}));
    TIONavEnableDisplay(YES);TIONavOfferDisplay(TIONavDisplay(@"navigating",3,@"测试道路",100,700,500,YES));TIONavPump();TIONavObserveEvent(Event(device,[p.last[@"sequence"] unsignedIntValue],@{@"code":@5}));NSCAssert([TIONavTransportStatus()[@"uncertain"] boolValue]&&![TIONavTransportStatus()[@"enabled"] boolValue],@"Negative ACK stops writes");
    TIONavRefreshConnection();TIONavObserveEvent(Event(device,[p.last[@"sequence"] unsignedIntValue],baseline));TIONavEnableDisplay(YES);TIONavOfferDisplay(TIONavDisplay(@"navigating",9,@"超时夹具",100,700,500,YES));TIONavPump();NSUInteger sends=p.sends;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,13*NSEC_PER_SEC),dispatch_get_main_queue(),^{TIONavPump();NSCAssert([TIONavTransportStatus()[@"uncertain"] boolValue],@"Timeout becomes unknown");TIONavPump();NSCAssert(p.sends==sends,@"No timeout retransmit");
        TIONavTestNotice();NSCAssert(p.sends==sends+1&&[p.business isEqual:@15],@"Automatic baseline read, no notification before ACK");
        TIONavObserveEvent(Event(device,[p.last[@"sequence"] unsignedIntValue],baseline));
        NSCAssert([p.business isEqual:@21]&&[p.last[@"type"] isEqual:@2],@"Notification protocol, not A2UI or ASR");
        NSString *uid=p.last[@"json"][@"notificationUID"];NSCAssert(uid.length,@"Decimal UID");NSUInteger count=p.sends;
        NSDictionary *(^statusEvent)(NSString *,NSString *,id)=^NSDictionary *(NSString *dev,NSString *u,id state){return @{@"eventType":@"messageReceived",@"message":@{@"businessId":@21,@"deviceId":dev,@"payload":TIOA2UIPacket(3,0,@{@"notificationUID":u,@"state":state})}};};
        TIONavObserveEvent(statusEvent(@"wrong",uid,@1));TIONavObserveEvent(statusEvent(device,@"wrong",@1));TIONavObserveEvent(statusEvent(device,uid,@YES));
        NSCAssert([TIONavTransportStatus()[@"noticePending"] boolValue],@"Wrong device, UID and boolean ignored");
        TIONavObserveEvent(statusEvent(device,uid,@1));NSCAssert(![TIONavTransportStatus()[@"noticePending"] boolValue],@"Matching notification status");
        TIONavTestNotice();NSCAssert(p.sends==count,@"Manual test respects cooldown");
        TIONavEnableNotices(YES);TIONavOfferDisplay(TIONavDisplay(@"navigating",3,@"模拟道路",70,600,500,YES));TIONavPump();NSCAssert(p.sends==count,@"Auto callback respects cooldown");
        TIONavObserveEvent(statusEvent(device,uid,@3));NSCAssert(![TIONavTransportStatus()[@"notices"] boolValue],@"DND pauses auto reminders");
        TIONavEnableNotices(NO);TIONavPump();NSCAssert(p.sends==count,@"No sends after stop");
        NSString *report=@"PASS: simulator fake RNLink only. Baseline gate, wrong device/sequence, single flight, owned uninstall, negative ACK, timeout/no retry; notification business/type, matching UID, boolean rejection, cooldown, DND pause and stop.";
        [report writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/navigation-transport-test.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];NSLog(@"%@",report);
    });
}
