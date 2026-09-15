#import "A2UIProbe.h"
#include <assert.h>
int main(void){@autoreleasepool{
    NSString *identifier=@"turbo_ui_7392";
    assert(TIOA2UITransportAllowed(YES,YES,YES,600,NO));
    assert(!TIOA2UITransportAllowed(NO,YES,YES,600,NO));
    assert(TIOA2UITransportAllowed(NO,YES,YES,0,NO));
    assert(!TIOA2UITransportAllowed(YES,YES,NO,0,NO));
    assert(!TIOA2UITransportAllowed(YES,NO,YES,0,NO));
    assert(!TIOA2UITransportAllowed(YES,YES,YES,0,YES));
    for(NSNumber *layout in @[@NO,@YES]){NSDictionary *j=TIOA2UIInstall(identifier,layout.boolValue);NSData *d=TIOA2UIPacket(18,0xf1234567,j);NSDictionary *e=TIOA2UIDecode(d);assert([e[@"type"] isEqual:@18]);assert([e[@"sequence"] unsignedIntValue]==0xf1234567);assert([e[@"json"] isEqual:j]);
        NSDictionary *outer=j[@"payload"][@"data"];assert([outer[@"type"] isEqual:@"a2ui"]);assert(!outer[@"widget"]);NSDictionary *extra=[NSJSONSerialization JSONObjectWithData:[outer[@"extras"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];assert([extra[@"widgetId"] isEqual:identifier]);assert(!extra[@"refreshInterval"]);assert([extra[@"uiContent"][@"updateComponents"][@"components"] count]==(layout.boolValue?6:1));
        for(NSUInteger n=0;n<d.length;n++){NSDictionary *shortPacket=TIOA2UIDecode([d subdataWithRange:NSMakeRange(0,n)]);assert(!shortPacket||[shortPacket[@"sequence"] unsignedIntValue]!=0xf1234567);}
    }
    assert(!TIOA2UIInstall(@"weather",NO));assert(!TIOA2UIUninstall(@"../existing"));assert(!TIOA2UIInstall(@"turbo_ui_A",NO));
    assert([TIOA2UIUninstall(identifier)[@"payload"][@"data"] count]==1);
    NSData *ack=TIOA2UIPacket(19,500,@{@"code":@0,@"err_msg":@"",@"data":NSNull.null});assert([TIOA2UIDecode(ack)[@"sequence"] isEqual:@500]);
    NSMutableData *bad=[ack mutableCopy];uint8_t duplicate[]={8,1};[bad appendBytes:duplicate length:2];assert(!TIOA2UIDecode(bad));
    assert(!TIOA2UIPacket(18,1,@{@"big":[@"字" stringByPaddingToLength:8000 withString:@"字" startingAtIndex:0]}));
    NSLog(@"PASS: A2UI fixed fixtures, PB sequence, truncation, duplicate, size and owned-ID guards; no device I/O");
}return 0;}
