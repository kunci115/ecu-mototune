import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! Garmin's own activity grammar, so nothing has to be learned:
//!   START: idle → start · recording → pause + Resume/Save/Discard · paused → that menu again
//!   BACK:  recording → marker (lap) · idle → leave the app
//!   UP / DOWN / swipe: pages
class RideDelegate extends WatchUi.BehaviorDelegate {
    private var _view as RideView;

    public function initialize(view as RideView) { BehaviorDelegate.initialize(); _view = view; }

    public function onSelect() as Boolean {
        if (!_view.hasSession()) { _view.startRecording(); }
        else { _view.pause(); WatchUi.pushView(new $.PauseMenu(), new $.PauseMenuDelegate(_view), WatchUi.SLIDE_UP); }
        return true;
    }

    public function onBack() as Boolean {
        if (_view.isRecording()) { _view.mark(); return true; }
        if (_view.hasSession()) { WatchUi.pushView(new $.PauseMenu(), new $.PauseMenuDelegate(_view), WatchUi.SLIDE_UP); return true; }
        return false;                                // idle: let the system close the app
    }

    public function onNextPage() as Boolean { _view.nextPage(); return true; }
    public function onPreviousPage() as Boolean { _view.prevPage(); return true; }
    public function onSwipe(evt as SwipeEvent) as Boolean {
        var d = evt.getDirection();
        if (d == WatchUi.SWIPE_UP || d == WatchUi.SWIPE_LEFT) { _view.nextPage(); return true; }
        if (d == WatchUi.SWIPE_DOWN || d == WatchUi.SWIPE_RIGHT) { _view.prevPage(); return true; }
        return false;
    }
}

class PauseMenu extends WatchUi.Menu2 {
    public function initialize() {
        Menu2.initialize({:title => "Paused"});
        addItem(new WatchUi.MenuItem("Resume", null, :resume, null));
        addItem(new WatchUi.MenuItem("Save ride", null, :save, null));
        addItem(new WatchUi.MenuItem("Discard", "no file kept", :discard, null));
    }
}

class PauseMenuDelegate extends WatchUi.Menu2InputDelegate {
    private var _view as RideView;
    public function initialize(view as RideView) { Menu2InputDelegate.initialize(); _view = view; }

    public function onSelect(item as MenuItem) as Void {
        var id = item.getId();
        if (id == :save) {
            var line = _view.finish(true);
            WatchUi.switchToView(new $.SummaryView("Saved", line), new $.SummaryDelegate(), WatchUi.SLIDE_DOWN);
        } else if (id == :discard) {
            var line = _view.finish(false);
            WatchUi.switchToView(new $.SummaryView("Discarded", line), new $.SummaryDelegate(), WatchUi.SLIDE_DOWN);
        } else {
            WatchUi.popView(WatchUi.SLIDE_DOWN);
            _view.resume();
        }
    }

    public function onBack() as Void {              // BACK on the pause menu = resume, like a native activity
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        _view.resume();
    }
}

//! After save/discard: a short summary; any key or tap returns to the checklist.
class SummaryView extends WatchUi.View {
    private var _title as String;
    private var _line as String;
    public function initialize(title as String, line as String) { View.initialize(); _title = title; _line = line; }
    public function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK); dc.clear();
        dc.setColor(_title.equals("Saved") ? Graphics.COLOR_GREEN : Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.22, Graphics.FONT_LARGE, _title, Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.45, Graphics.FONT_SMALL, _line, Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.80, Graphics.FONT_XTINY, "any button to continue", Graphics.TEXT_JUSTIFY_CENTER);
    }
}

class SummaryDelegate extends WatchUi.BehaviorDelegate {
    public function initialize() { BehaviorDelegate.initialize(); }
    public function onSelect() as Boolean { WatchUi.popView(WatchUi.SLIDE_DOWN); return true; }
    public function onBack() as Boolean { WatchUi.popView(WatchUi.SLIDE_DOWN); return true; }
    public function onTap(evt as ClickEvent) as Boolean { WatchUi.popView(WatchUi.SLIDE_DOWN); return true; }
}
