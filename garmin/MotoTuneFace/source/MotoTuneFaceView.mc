import Toybox.Activity;
import Toybox.Application;
import Toybox.Complications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.WatchUi;

//! The MotoTune watch face. Same visual language as the app: AMOLED black, cyan accent, tracked labels.
//! Time big in the middle, AFR from the MotoTune Ride complication above it, HR · battery · date around.
class MotoTuneFaceView extends WatchUi.WatchFace {
    const ACCENT = 0x25E0D0;
    const GOOD = 0x34D399;
    const BAD = 0xF87171;
    const TEXT = 0xEDF1F5;
    const DIM = 0x8A93A0;
    const FAINT = 0x3A424D;

    private var _afrId as Complications.Id? = null;
    private var _afr as String? = null;          // last published value ("12.8")
    private var _afrAt as Number = 0;            // when we last received an update
    private var _sleeping as Boolean = false;

    public function initialize() {
        WatchFace.initialize();
    }

    public function onLayout(dc as Dc) as Void {
        findAfrComplication();
    }

    public function onShow() as Void {
        if (_afrId == null) { findAfrComplication(); }
    }

    //! Look for the complication MotoTune Ride publishes (short label "AFR") and subscribe to its updates.
    private function findAfrComplication() as Void {
        if (!(Toybox has :Complications)) { return; }
        try {
            var it = Complications.getComplications();
            var c = it.next();
            while (c != null) {
                var label = c.shortLabel;
                if (label != null && label.equals("AFR")) {
                    _afrId = c.complicationId;
                    if (c.value != null) { _afr = c.value.toString(); _afrAt = Time.now().value(); }
                    break;
                }
                c = it.next();
            }
            if (_afrId != null) {
                Complications.registerComplicationChangeCallback(method(:onComplicationChanged));
                Complications.subscribeToUpdates(_afrId);
            }
        } catch (e) {
            _afr = null;
        }
    }

    public function onComplicationChanged(id as Complications.Id) as Void {
        if (_afrId != null && id.equals(_afrId)) {
            try {
                var c = Complications.getComplication(id);
                if (c.value != null) { _afr = c.value.toString(); _afrAt = Time.now().value(); }
            } catch (e) {}
            WatchUi.requestUpdate();
        }
    }

    public function onEnterSleep() as Void { _sleeping = true; WatchUi.requestUpdate(); }
    public function onExitSleep() as Void { _sleeping = false; WatchUi.requestUpdate(); }

    public function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        var now = Time.now();
        var g = Gregorian.info(now, Time.FORMAT_MEDIUM);
        var hx = dc.getFontHeight(Graphics.FONT_XTINY);

        // ---- AFR band (top): label, value, freshness
        var age = _afrAt == 0 ? null : now.value() - _afrAt;
        var fresh = age != null && age < 30;
        var afrText = _afr == null ? "--.-" : _afr;
        var afrColor = DIM;
        if (fresh && _afr != null) {
            var v = _afr.toFloat();
            afrColor = (v != null && v >= 13.6) ? BAD : ((v != null && v <= 11.5) ? 0x60A5FA : GOOD);
        }
        var yAfrLabel = (h * 0.11).toNumber();
        dc.setColor(DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yAfrLabel, Graphics.FONT_XTINY, fresh ? "A F R" : (age == null ? "A F R  ·  no data" : "A F R  ·  " + (age < 3600 ? (age / 60).format("%d") + " min ago" : "old")), Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(afrColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yAfrLabel + hx, Graphics.FONT_NUMBER_MILD, afrText, Graphics.TEXT_JUSTIFY_CENTER);

        // ---- time (middle), always on; dimmer in sleep
        var settings = System.getDeviceSettings();
        var hour = g.hour;
        if (!settings.is24Hour) { hour = hour % 12; if (hour == 0) { hour = 12; } }
        var timeText = hour.format("%d") + ":" + g.min.format("%02d");
        var timeFont = Graphics.FONT_NUMBER_THAI_HOT;
        var th = dc.getFontHeight(timeFont);
        dc.setColor(_sleeping ? DIM : TEXT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h / 2 - th / 2 + (h * 0.03).toNumber(), timeFont, timeText, Graphics.TEXT_JUSTIFY_CENTER);
        if (!_sleeping) {
            dc.setColor(ACCENT, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h / 2 + th / 2 - (h * 0.02).toNumber(), Graphics.FONT_XTINY, (g.day_of_week as String).toUpper() + "  " + g.day.format("%d") + "  " + (g.month as String).toUpper(), Graphics.TEXT_JUSTIFY_CENTER);
        }

        // ---- bottom band: heart rate · battery
        var hr = Activity.getActivityInfo();
        var hrText = (hr != null && hr.currentHeartRate != null) ? (hr.currentHeartRate as Number).format("%d") : "--";
        var batt = System.getSystemStats().battery;
        var yBot = (h * 0.76).toNumber();
        dc.setColor(TEXT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w * 0.34, yBot, Graphics.FONT_SMALL, hrText, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(w * 0.66, yBot, Graphics.FONT_SMALL, batt.format("%d") + "%", Graphics.TEXT_JUSTIFY_CENTER);
        var sh = dc.getFontHeight(Graphics.FONT_SMALL);
        dc.setColor(DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w * 0.34, yBot + sh - 4, Graphics.FONT_XTINY, "BPM", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(w * 0.66, yBot + sh - 4, Graphics.FONT_XTINY, "BATT", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(FAINT, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cx, yBot + 4, cx, yBot + sh + hx - 6);

        // ---- bezel: thin accent arc as the brand mark, battery as a faint arc at the bottom
        dc.setPenWidth(4);
        dc.setColor(FAINT, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(cx, h / 2, w / 2 - 4, Graphics.ARC_CLOCKWISE, 225, -45);
        dc.setColor(fresh ? afrColor : ACCENT, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(cx, h / 2, w / 2 - 4, Graphics.ARC_CLOCKWISE, 225, 225 - (270 * batt / 100).toNumber());
        dc.setPenWidth(1);
    }
}
