import { ArrayList } from '@kit.ArkTS';
import { AMap, MapView, MapViewManager, MapViewComponent, LatLng, LatLngBounds, CameraUpdateFactory, PolylineOptions, MarkerOptions } from '@amap/amap_lbs_navi';

@Component
export struct AmapPreview {
  @Prop @Watch('redraw') route:string='';
  @Prop @Watch('redraw') destination:string='';
  @Prop selectable:boolean=true;
  onSelect:(coordinate:string)=>void=(_coordinate:string):void=>{};
  private name:string='turboio-native-navigation';
  private map:AMap|undefined=undefined;
  private view:MapView|undefined=undefined;
  private visible:boolean=false;
  private created=(view?:MapView,name?:string):void=>{
    if(!this.visible||name!==this.name||!view)return;
    this.view=view;view.onCreate();view.onResume();
    view.getMapAsync((map:AMap):void=>{
      if(!this.visible)return;this.map=map;map.getUiSettings()?.setZoomControlsEnabled(true);
      map.moveCamera(CameraUpdateFactory.newLatLngZoom(new LatLng(39.9042,116.4074),11));
      map.setOnMapClickListener((point:LatLng):void=>{if(this.visible&&this.selectable)this.onSelect(`${point.longitude.toFixed(6)},${point.latitude.toFixed(6)}`);});
      this.redraw();
    });
  };
  aboutToAppear():void{this.visible=true;MapViewManager.getInstance().registerMapViewCreatedCallback(this.created);}
  aboutToDisappear():void{this.visible=false;MapViewManager.getInstance().unregisterMapViewCreatedCallback(this.created);this.view?.onPause();this.view?.onDestroy();this.map=undefined;this.view=undefined;}
  private parse(value:string):LatLng|undefined {
    const p=value.split(',').map(Number);if(p.length!==2||!p.every(Number.isFinite)||Math.abs(p[0])>180||Math.abs(p[1])>90)return undefined;return new LatLng(p[1],p[0]);
  }
  private redraw():void {
    if(!this.map)return;this.map.clear();const points=new ArrayList<LatLng>();
    for(const value of this.route.split(';')){const p=this.parse(value);if(p)points.add(p);}
    if(points.length>1){
      this.map.addPolyline(new PolylineOptions().addAll(points).setWidth(14).setColor(0xff24b58a));
      let minLat=90,maxLat=-90,minLon=180,maxLon=-180;
      for(let i=0;i<points.length;i++){const p=points[i];minLat=Math.min(minLat,p.latitude);maxLat=Math.max(maxLat,p.latitude);minLon=Math.min(minLon,p.longitude);maxLon=Math.max(maxLon,p.longitude);}
      this.map.moveCamera(CameraUpdateFactory.newLatLngBounds(new LatLngBounds(new LatLng(minLat-0.0001,minLon-0.0001),new LatLng(maxLat+0.0001,maxLon+0.0001)),40));
    }
    const selected=this.parse(this.destination);
    if(selected){this.map.addMarker(new MarkerOptions().setPosition(selected).setTitle('目的地'));if(points.length<2)this.map.moveCamera(CameraUpdateFactory.newLatLngZoom(selected,15));}
  }
  build(){MapViewComponent({mapViewName:this.name}).height(260).width('100%')}
}
