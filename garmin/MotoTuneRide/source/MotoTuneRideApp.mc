import Toybox.Application;
import Toybox.Background;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.Position;
import Toybox.System;
import Toybox.WatchUi;

//! Entry point. Keeps the latest ECU snapshot pushed by the phone and hands it to the view.
//! Also the host for the background service (complication updates) and the glance.
(:background :glance)
class MotoTuneRideApp extends Application.AppBase {
    private var _view as RideView?;

    public function initialize() {
        AppBase.initialize();
        if (Communications has :registerForPhoneAppMessages) {
            Communications.registerForPhoneAppMessages(method(:onPhone));
        }
    }

    public function onStart(state as Dictionary?) as Void {
        // phone messages wake the background service when the app isn't open → watch-face AFR
        if (Toybox has :Background) { Background.registerForPhoneAppMessageEvent(); }
        // GPS on from the start so the first seconds of a ride are already positioned.
        // Ask for the most precise constellation set the watch supports (FR265: multi-band L1+L5).
        var started = false;
        if (Position has :CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5 && Position has :hasConfigurationSupport) {
            var cfgs = [Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5, Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1, Position.CONFIGURATION_GPS];
            for (var i = 0; i < cfgs.size() && !started; i++) {
                if (Position.hasConfigurationSupport(cfgs[i])) {
                    Position.enableLocationEvents({:acquisitionType => Position.LOCATION_CONTINUOUS, :configuration => cfgs[i]}, method(:onPosition));
                    started = true;
                }
            }
        }
        if (!started) { Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition)); }
    }

    public function onStop(state as Dictionary?) as Void {
        if (_view != null && _view.hasSession()) { _view.finish(true); }   // leaving the app mid-ride still saves the FIT
        Position.enableLocationEvents(Position.LOCATION_DISABLE, null);
    }

    public function onPosition(info as Position.Info) as Void {
        if (_view != null) { _view.onPosition(info); }
    }

    public function getInitialView() as [Views] or [Views, InputDelegates] {
        _view = new $.RideView();
        return [_view, new $.RideDelegate(_view)];
    }

    public function getServiceDelegate() as [System.ServiceDelegate] {
        return [new $.RideService()];
    }

    public function getGlanceView() as [GlanceView] or [GlanceView, GlanceViewDelegate] or Null {
        return [new $.RideGlance()];
    }

    //! The background service handed us a snapshot while we were starting: show it right away.
    public function onBackgroundData(data as PersistableType) as Void {
        if (data instanceof Dictionary && _view != null) { _view.onEcu(data as Dictionary); WatchUi.requestUpdate(); }
    }

    //! Phone → watch. One small dictionary per second while the phone is connected to the ECU:
    //! {"rpm", "afr" (×10), "tgt" (×10), "tps", "gear", "pulls", "map", "lean" (0/1), "bpw" (×100)}
    public function onPhone(msg as Communications.PhoneAppMessage) as Void {
        var data = msg.data;
        if (data instanceof Dictionary) {
            $.publishSnapshot(data as Dictionary);        // keep the watch-face complication current too
            if (_view != null) { _view.onEcu(data as Dictionary); }
        }
        WatchUi.requestUpdate();
    }
}
