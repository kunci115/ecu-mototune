import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.Position;
import Toybox.WatchUi;

//! Entry point. Keeps the latest ECU snapshot pushed by the phone and hands it to the view.
class MotoTuneRideApp extends Application.AppBase {
    private var _view as RideView?;

    public function initialize() {
        AppBase.initialize();
        if (Communications has :registerForPhoneAppMessages) {
            Communications.registerForPhoneAppMessages(method(:onPhone));
        }
    }

    public function onStart(state as Dictionary?) as Void {
        // GPS on from the start so the first seconds of a ride are already positioned
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
    }

    public function onStop(state as Dictionary?) as Void {
        if (_view != null) { _view.stopRecording(true); }
        Position.enableLocationEvents(Position.LOCATION_DISABLE, null);
    }

    public function onPosition(info as Position.Info) as Void {
        if (_view != null) { _view.onPosition(info); }
    }

    public function getInitialView() as [Views] or [Views, InputDelegates] {
        _view = new $.RideView();
        return [_view, new $.RideDelegate(_view)];
    }

    //! Phone → watch. One small dictionary per second while the phone is connected to the ECU:
    //! {"rpm", "afr" (×10), "tgt" (×10), "tps", "gear", "pulls", "map", "lean" (0/1), "bpw" (×100)}
    public function onPhone(msg as Communications.PhoneAppMessage) as Void {
        var data = msg.data;
        if (data instanceof Dictionary && _view != null) {
            _view.onEcu(data as Dictionary);
        }
        WatchUi.requestUpdate();
    }
}
