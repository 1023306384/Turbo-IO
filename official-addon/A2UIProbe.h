#import <Foundation/Foundation.h>
NSData *TIOA2UIPacket(uint32_t type,uint32_t sequence,NSDictionary *json);
NSDictionary *TIOA2UIDecode(NSData *data);
NSDictionary *TIOA2UIInstall(NSString *identifier,BOOL layout);
NSDictionary *TIOA2UIUninstall(NSString *identifier);
BOOL TIOA2UITransportAllowed(BOOL query,BOOL context,BOOL active,NSTimeInterval age,BOOL pending);
void TIOA2UIObserveCall(id plugin,NSString *method,NSDictionary *args);
void TIOA2UIObserveEvent(NSDictionary *event);
@class UIViewController;
UIViewController *TIOA2UIController(void);
