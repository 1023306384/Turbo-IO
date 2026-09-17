import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { probeSession } from '../ProbeSession';

export default class EntryAbility extends UIAbility {
  private mainWindow:window.Window|undefined=undefined;
  private updateInsets=():void=>{
    const main=this.mainWindow;if(!main)return;
    try {
      const ui=main.getUIContext();
      const top=main.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
      const bottom=main.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
      AppStorage.setOrCreate('turboTopInset',ui.px2vp(top));
      AppStorage.setOrCreate('turboBottomInset',ui.px2vp(bottom));
    }catch(_){}
  };
  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.getMainWindow().then(async(main:window.Window):Promise<void>=>{
      this.mainWindow=main;
      await main.setWindowLayoutFullScreen(true);
      main.setWindowBackgroundColor('#0D1720');
      await main.setWindowSystemBarProperties({statusBarColor:'#00000000',navigationBarColor:'#00000000',statusBarContentColor:'#FFFFFF',navigationBarContentColor:'#FFFFFF'});
      this.updateInsets();main.on('avoidAreaChange',this.updateInsets);
    }).catch((error:BusinessError)=>{hilog.warn(0,'TurboIO','Immersive setup code=%{public}d',error.code);});
    try {
      windowStage.loadContent('pages/Index', (error: BusinessError): void => {
        if (error.code) { hilog.error(0, 'TurboIO', 'Page load failed, code=%{public}d', error.code); }
      });
    } catch (error) {
      hilog.error(0, 'TurboIO', 'Window unavailable, code=%{public}d', (error as BusinessError).code);
    }
  }

  onForeground(): void { probeSession.resume(this.context); }

  onBackground(): void {
    probeSession.suspend();
  }

  onDestroy(): void {
    if(this.mainWindow){try{this.mainWindow.off('avoidAreaChange',this.updateInsets);}catch(_){}this.mainWindow=undefined;}
    probeSession.foreground = false;
    probeSession.stop();
  }
}
