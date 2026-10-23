import Toybox.Lang;
import Toybox.WatchUi;

//! Buttons: START/SELECT = start · pause, BACK = menu while recording (save / discard),
//! UP or DOWN (or a tap) = "feel" marker. One-handed, glove-friendly.
class RideDelegate extends WatchUi.BehaviorDelegate {
    private var _view as RideView;

    public function initialize(view as RideView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    public function onSelect() as Boolean {
        if (_view.isRecording()) {
            WatchUi.pushView(new $.StopMenu(), new $.StopMenuDelegate(_view), WatchUi.SLIDE_UP);
        } else {
            _view.startRecording();
        }
        return true;
    }

    public function onBack() as Boolean {
        if (_view.isRecording()) {
            WatchUi.pushView(new $.StopMenu(), new $.StopMenuDelegate(_view), WatchUi.SLIDE_UP);
            return true;                 // never leave the app mid-ride by accident
        }
        return false;
    }

    public function onNextPage() as Boolean { _view.mark(); return true; }
    public function onPreviousPage() as Boolean { _view.mark(); return true; }
    public function onTap(evt as ClickEvent) as Boolean { _view.mark(); return true; }
}

class StopMenu extends WatchUi.Menu2 {
    public function initialize() {
        Menu2.initialize({:title => "Ride"});
        addItem(new WatchUi.MenuItem("Resume", null, :resume, null));
        addItem(new WatchUi.MenuItem("Save ride", null, :save, null));
        addItem(new WatchUi.MenuItem("Discard", null, :discard, null));
    }
}

class StopMenuDelegate extends WatchUi.Menu2InputDelegate {
    private var _view as RideView;
    public function initialize(view as RideView) { Menu2InputDelegate.initialize(); _view = view; }
    public function onSelect(item as MenuItem) as Void {
        var id = item.getId();
        WatchUi.popView(WatchUi.SLIDE_DOWN);          // leave the menu first so the view redraws with the result
        if (id == :save) { _view.stopRecording(true); }
        else if (id == :discard) { _view.stopRecording(false); }
        else { _view.toastResume(); }
    }
}
