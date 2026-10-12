import 'package:flutter/services.dart';
import '../foundation/app.dart';

///监听鼠标侧键, 若为下键, 则调用返回
void listenMouseSideButtonToBack() async{
  if(!App.isWindows){
    return;
  }
  const channel = EventChannel("pixes/mouse");
  await for(var res in channel.receiveBroadcastStream()){
    if(res == 0){
      App.rootNavigatorKey.currentState?.maybePop();
    }
  }
}