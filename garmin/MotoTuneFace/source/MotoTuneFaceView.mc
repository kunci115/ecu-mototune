import Toybox.Activity;
import Toybox.Application;
import Toybox.Complications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.WatchUi;

//! The MotoTune watch face: AFR on top, time in the middle (date · ♥ · battery under it), RPM | TPS at the
//! bottom — all three engine values come from the complications MotoTune Ride publishes.
class MotoTuneFaceView extends WatchUi.WatchFace {
    const ACCENT = 0x25E0D0;
    const GOOD = 0x34D399;
    const BAD = 0xF87171;
    const RICH = 0x60A5FA;
    const TEXT = 0xEDF1F5;
    const DIM = 0x8A93A0;
    const FAINT = 0x3A424D;

    private var _ids as Dictionary = {};          // "AFR"/"RPM"/"TPS" → Complications.Id
    private var _vals as Dictionary = {};         // label → last value (String or Number)
    private var _at as Number = 0;
    private var _sleeping as Boolean = false;
    private var _subscribed as Boolean = false;

    public function initialize() { WatchFace.initialize(); }
    public function onLayout(dc as Dc) as Void { subscribe(); }
    public function onShow() as Void { if (!_subscribed) { subscribe(); } }

    private function subscribe() as Void {
        if (!(Toybox has :Complications)) { return; }
        try {
            var it = Complications.getComplications();
            var c = it.next();
            while (c != null) {
                var label = c.shortLabel;
                if (label != null && (label.equals("AFR") || label.equals("RPM") || label.equals("TPS"))) {
                    _ids[label] = c.complicationId;
                    if (c.value != null) { _vals[label] = c.value; _at = Time.now().value(); }
                }
                c = it.next();
            }
            if (_ids.size() > 0) {
                Complications.registerComplicationChangeCallback(method(:onComplicationChanged));
                var keys = _ids.keys();
                for (var i = 0; i < keys.size(); i++) { Complications.subscribeToUpdates(_ids[keys[i]] as Complications.Id); }
                _subscribed = true;
            }
        } catch (e) {}
    }

    public function onComplicationChanged(id as Complications.Id) as Void {
        var keys = _ids.keys();
        for (var i = 0; i < keys.size(); i++) {
            if (id.equals(_ids[keys[i]])) {
                try {
                    var c = Complications.getComplication(id);
                    if (c.value != null) { _vals[keys[i]] = c.value; _at = Time.now().value(); }
                } catch (e) {}
            }
        }
        WatchUi.requestUpdate();
    }

    public function onEnterSleep() as Void { _sleeping = true; WatchUi.requestUpdate(); }
    public function onExitSleep() as Void { _sleeping = false; WatchUi.requestUpdate(); }

    private function text(v) as String { return v == null ? "--" : v.toString(); }

    public function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        var now = Time.now();
        var g = Gregorian.info(now, Time.FORMAT_MEDIUM);
        var hx = dc.getFontHeight(Graphics.FONT_XTINY);
        var age = _at == 0 ? null : now.value() - _at;
        var fresh = age != null && age < 30;

        // ---- top: AFR
        var afrStr = _vals.hasKey("AFR") ? text(_vals["AFR"]) : "--.-";
        var afrColor = DIM;
        if (fresh && _vals.hasKey("AFR")) {
            var v = afrStr.toFloat();
            afrColor = (v != null && v >= 13.6) ? BAD : ((v != null && v <= 11.5) ? RICH : GOOD);
        }
        var yTop = (h * 0.07).toNumber();
        dc.setColor(DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yTop, Graphics.FONT_XTINY, fresh ? "A F R" : (age == null ? "A F R  ·  no data" : "A F R  ·  " + (age < 3600 ? (age / 60).format("%d") + " min" : "old")), Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(afrColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yTop + hx - 4, Graphics.FONT_LARGE, afrStr, Graphics.TEXT_JUSTIFY_CENTER);

        // ---- middle: time, then one line "TUE 23 OCT · ♥ 78 · 86%"
        var settings = System.getDeviceSettings();
        var hour = g.hour;
        if (!settings.is24Hour) { hour = hour % 12; if (hour == 0) { hour = 12; } }
        var timeFont = Graphics.FONT_NUMBER_HOT;
        var th = dc.getFontHeight(timeFont);
        var yTime = h / 2 - th / 2 + (h * 0.02).toNumber();
        dc.setColor(_sleeping ? DIM : TEXT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yTime, timeFont, hour.format("%d") + ":" + g.min.format("%02d"), Graphics.TEXT_JUSTIFY_CENTER);
        var info = Activity.getActivityInfo();
        var hr = (info != null && info.currentHeartRate != null) ? (info.currentHeartRate as Number).format("%d") : "--";
        var batt = System.getSystemStats().battery;
        dc.setColor(_sleeping ? FAINT : ACCENT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yTime + th - (h * 0.02).toNumber(), Graphics.FONT_XTINY,
                    (g.day_of_week as String).toUpper() + " " + g.day.format("%d") + " " + (g.month as String).toUpper() + "  ·  " + hr + " bpm  ·  " + batt.format("%d") + "%",
                    Graphics.TEXT_JUSTIFY_CENTER);

        // ---- bottom: RPM | TPS
        var yBot = (h * 0.76).toNumber();
        var col = fresh ? TEXT : DIM;
        dc.setColor(col, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w * 0.33, yBot, Graphics.FONT_SMALL, _vals.hasKey("RPM") ? text(_vals["RPM"]) : "--", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(w * 0.67, yBot, Graphics.FONT_SMALL, (_vals.hasKey("TPS") ? text(_vals["TPS"]) : "--") + "%", Graphics.TEXT_JUSTIFY_CENTER);
        var sh = dc.getFontHeight(Graphics.FONT_SMALL);
        dc.setColor(DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w * 0.33, yBot + sh - 6, Graphics.FONT_XTINY, "RPM", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(w * 0.67, yBot + sh - 6, Graphics.FONT_XTINY, "TPS", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(FAINT, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cx, yBot + 4, cx, yBot + sh + hx - 10);

        // ---- bezel: faint track + battery arc in the AFR colour
        dc.setPenWidth(4);
        dc.setColor(FAINT, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(cx, h / 2, w / 2 - 4, Graphics.ARC_CLOCKWISE, 225, -45);
        dc.setColor(fresh ? afrColor : ACCENT, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(cx, h / 2, w / 2 - 4, Graphics.ARC_CLOCKWISE, 225, 225 - (270 * batt / 100).toNumber());
        dc.setPenWidth(1);
    }
}
