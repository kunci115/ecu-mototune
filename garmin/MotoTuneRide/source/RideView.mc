import Toybox.Activity;
import Toybox.ActivityRecording;
import Toybox.Attention;
import Toybox.Communications;
import Toybox.FitContributor;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.Sensor;
import Toybox.System;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

//! MotoTune design language on the wrist: AMOLED black, cyan accent, tracked small-caps labels,
//! big numerals, arc gauges around the bezel, and cyan arcs at the physical buttons as hints.
//!   START (top right): start · pause · resume     UP (top left): mark · save when paused
//!   BACK (bottom right): menu · exit when idle     DOWN (bottom left) / swipe: next page
class RideView extends WatchUi.View {
    enum { PAGE_ENGINE, PAGE_MIXTURE, PAGE_DYNO, PAGE_RIDE, PAGE_COUNT }

    // palette (same tokens as the phone app)
    const ACCENT = 0x25E0D0;
    const GOOD = 0x34D399;
    const WARN = 0xFBBF24;
    const BAD = 0xF87171;
    const TEXT = 0xEDF1F5;
    const DIM = 0x8A93A0;
    const FAINT = 0x3A424D;
    const RICH = 0x60A5FA;
    // physical button angles on the FR265 bezel (degrees, 0 = 3 o'clock, counter-clockwise)
    const ANG_START = 32;
    const ANG_BACK = 328;
    const ANG_UP = 180;
    const ANG_DOWN = 215;

    private var _session as Session?;
    private var _paused as Boolean = false;
    private var _page as Number = PAGE_ENGINE;
    private var _ecu as Dictionary = {};
    private var _lastEcuAt as Number = 0;
    private var _wasLean as Boolean = false;
    private var _flashUntil as Number = 0;
    private var _markers as Number = 0;
    private var _hr as Number? = null;
    private var _gpsQuality as Number = 0;
    private var _speedMps as Float? = null;
    private var _lastPosAt as Number = 0;          // seconds; 0 = no position event yet
    private var _gpsFallback as Boolean = false;
    private var _startedAt as Number = 0;
    private var _maxRpm as Number = 0;
    private var _toast as String? = null;
    private var _toastAt as Number = 0;
    private var _ticks as Number = 0;
    private var _timer as Timer.Timer = new Timer.Timer();
    private var _icon as BitmapResource?;
    private var _fRpm as Field?;
    private var _fAfr as Field?;
    private var _fTps as Field?;
    private var _fGear as Field?;

    public function initialize() { View.initialize(); }

    public function onLayout(dc as Dc) as Void {
        _icon = WatchUi.loadResource(Rez.Drawables.LauncherIcon) as BitmapResource;
    }

    public function onShow() as Void {
        Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
        Sensor.enableSensorEvents(method(:onSensor));
        _timer.start(method(:tick), 1000, true);
    }
    public function onHide() as Void { _timer.stop(); Sensor.enableSensorEvents(null); }
    public function onSensor(info as Sensor.Info) as Void { _hr = info.heartRate; }
    public function onPosition(info as Position.Info) as Void { _gpsQuality = info.accuracy; _speedMps = info.speed; _lastPosAt = Time.now().value(); }

    // ---- phone data -----------------------------------------------------------------------
    public function onEcu(d as Dictionary) as Void {
        _ecu = d;
        _lastEcuAt = Time.now().value();
        var lean = d.hasKey("lean") && (d["lean"] as Number) == 1;
        if (lean && !_wasLean) { buzz(2); _flashUntil = Time.now().value() + 1; }
        _wasLean = lean;
        if (d.hasKey("rpm")) { var r = d["rpm"] as Number; if (isRecording() && r > _maxRpm) { _maxRpm = r; } }
        if (isRecording()) {
            if (_fRpm != null && d.hasKey("rpm")) { _fRpm.setData(d["rpm"] as Number); }
            if (_fAfr != null && d.hasKey("afr")) { _fAfr.setData(d["afr"] as Number); }
            if (_fTps != null && d.hasKey("tps")) { _fTps.setData(d["tps"] as Number); }
            if (_fGear != null && d.hasKey("gear")) { _fGear.setData(d["gear"] as Number); }
        }
    }

    public function tick() as Void {
        _ticks += 1;
        // no position event at all after 15 s → the multi-band request may have been ignored; fall back to the plain call
        if (_ticks == 15 && _lastPosAt == 0 && !_gpsFallback) {
            _gpsFallback = true;
            Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
            toast("gps: plain mode");
        }
        if (_ticks % 10 == 0 && phoneConnected()) {
            Communications.transmit({"hr" => (_hr == null ? 0 : _hr), "rec" => isRecording() ? 1 : 0}, null, new $.QuietListener());
        }
        WatchUi.requestUpdate();
    }

    private function phoneConnected() as Boolean {
        var ds = System.getDeviceSettings();
        return ds != null && ds.phoneConnected;
    }
    private function ecuFresh() as Boolean { return (Time.now().value() - _lastEcuAt) < 5; }

    // ---- recording --------------------------------------------------------------------------
    public function isRecording() as Boolean { return _session != null && _session.isRecording(); }
    public function hasSession() as Boolean { return _session != null; }

    //! The ride is only worth recording when the phone is streaming the ECU — no ECU, no start.
    public function ecuLive() as Boolean {
        return ecuFresh() && _ecu.hasKey("ecu") && (_ecu["ecu"] as Number) == 1;
    }

    public function startRecording() as Void {
        if (!(Toybox has :ActivityRecording)) { toast("no FIT support"); return; }
        if (!ecuLive()) {
            toast(phoneConnected() ? "connect phone to ECU first" : "phone not connected");
            buzz(1); WatchUi.requestUpdate(); return;
        }
        try {
            var sport = Activity.SPORT_CYCLING;
            if (Activity has :SPORT_MOTORCYCLING) { sport = Activity.SPORT_MOTORCYCLING; }
            var s = ActivityRecording.createSession({:name => "MotoTune Ride", :sport => sport});
            _session = s;
            try {
                _fRpm  = s.createField("rpm",  0, FitContributor.DATA_TYPE_UINT16, {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "rpm"});
                _fAfr  = s.createField("afr",  1, FitContributor.DATA_TYPE_UINT16, {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "x0.1"});
                _fTps  = s.createField("tps",  2, FitContributor.DATA_TYPE_UINT8,  {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "%"});
                _fGear = s.createField("gear", 3, FitContributor.DATA_TYPE_UINT8,  {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "n"});
            } catch (e) {
                _fRpm = null; _fAfr = null; _fTps = null; _fGear = null;
                toast("fields off: " + e.getErrorMessage());
            }
            s.start();
            _paused = false; _startedAt = Time.now().value(); _markers = 0; _maxRpm = 0; _page = PAGE_ENGINE;
            buzz(1);
            if (_toast == null) { toast("recording"); }
        } catch (e) {
            _session = null;
            toast("start failed: " + e.getErrorMessage());
        }
        WatchUi.requestUpdate();
    }

    public function pause() as Void {
        var s = _session;
        if (s != null && s.isRecording()) { s.stop(); _paused = true; _toast = null; buzz(1); }
        WatchUi.requestUpdate();
    }

    public function resume() as Void {
        var s = _session;
        if (s != null && !s.isRecording()) { s.start(); _paused = false; toast("resumed"); }
        WatchUi.requestUpdate();
    }

    public function finish(save as Boolean) as String {
        var s = _session;
        if (s == null) { return "nothing to save"; }
        var line = "";
        try {
            if (s.isRecording()) { s.stop(); }
            if (save) {
                s.save();
                var dur = Time.now().value() - _startedAt;
                line = (dur / 60).format("%d") + ":" + (dur % 60).format("%02d") + "  ·  " + _markers + " marks\nmax " + _maxRpm + " rpm";
                toast("saved");
            } else { s.discard(); line = "no file kept"; toast("discarded"); }
        } catch (e) { line = "failed: " + e.getErrorMessage(); toast(line); }
        _session = null; _paused = false;
        _fRpm = null; _fAfr = null; _fTps = null; _fGear = null;
        WatchUi.requestUpdate();
        return line;
    }

    public function mark() as Void {
        _markers += 1;
        var s = _session;
        if (s != null && s.isRecording()) { s.addLap(); }
        if (phoneConnected()) {
            Communications.transmit({"mark" => Time.now().value(), "hr" => (_hr == null ? 0 : _hr), "n" => _markers}, null, new $.QuietListener());
        }
        buzz(1);
        toast("mark #" + _markers);
        WatchUi.requestUpdate();
    }

    public function nextPage() as Void { _page = (_page + 1) % PAGE_COUNT; WatchUi.requestUpdate(); }
    public function prevPage() as Void { _page = (_page + PAGE_COUNT - 1) % PAGE_COUNT; WatchUi.requestUpdate(); }

    private function buzz(times as Number) as Void {
        if (Attention has :vibrate) {
            var profile = [] as Array<Attention.VibeProfile>;
            for (var i = 0; i < times; i++) { profile.add(new Attention.VibeProfile(80, 300)); profile.add(new Attention.VibeProfile(0, 150)); }
            Attention.vibrate(profile);
        }
    }
    private function toast(msg as String) as Void { _toast = msg; _toastAt = Time.now().value(); System.println("MotoTune: " + msg); }

    // ---- drawing primitives -------------------------------------------------------------------
    private function label(dc as Dc, x as Number, y as Number, text as String, color as Number) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, Graphics.FONT_XTINY, text, Graphics.TEXT_JUSTIFY_CENTER);
    }

    //! A bezel arc from `a0` to `a1` degrees (counter-clockwise), `width` px thick, `inset` from the edge.
    private function arc(dc as Dc, a0 as Number, a1 as Number, color as Number, width as Number, inset as Number) as Void {
        var r = dc.getWidth() / 2;
        dc.setPenWidth(width);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(r, r, r - inset, Graphics.ARC_CLOCKWISE, a0, a1);
        dc.setPenWidth(1);
    }

    //! Gauge along the bezel: track from 225° down to -45° (270° sweep, like the app icon), fill by `frac`.
    private function gauge(dc as Dc, frac as Float, color as Number, redlineFrac as Float?) as Void {
        arc(dc, 225, -45, FAINT, 8, 6);
        if (redlineFrac != null) { arc(dc, 225 - (270 * redlineFrac).toNumber(), -45, 0x5A2A2A, 8, 6); }
        var f = frac < 0.0 ? 0.0 : (frac > 1.0 ? 1.0 : frac);
        if (f > 0.01) { arc(dc, 225, 225 - (270 * f).toNumber(), color, 8, 6); }
    }

    //! Cyan arc + word at a physical button, the way native screens hint "START".
    private function hint(dc as Dc, angle as Number, text as String?, color as Number) as Void {
        arc(dc, angle + 11, angle - 11, color, 6, 4);
        if (text == null) { return; }
        var r = dc.getWidth() / 2;
        var rad = Math.toRadians(angle);
        var x = r + (r - 34) * Math.cos(rad), y = r - (r - 34) * Math.sin(rad);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x.toNumber(), y.toNumber() - dc.getFontHeight(Graphics.FONT_XTINY) / 2, Graphics.FONT_XTINY, text,
                    angle > 90 && angle < 270 ? Graphics.TEXT_JUSTIFY_LEFT : Graphics.TEXT_JUSTIFY_RIGHT);
    }

    private function big(dc as Dc, y as Number, text as String, color as Number) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth() / 2, y, Graphics.FONT_NUMBER_THAI_HOT, text, Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function pair(dc as Dc, y as Number, lv as String, ll as String, rv as String, rl as String, color as Number) as Void {
        var w = dc.getWidth();
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w * 0.30, y, Graphics.FONT_NUMBER_MILD, lv, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(w * 0.70, y, Graphics.FONT_NUMBER_MILD, rv, Graphics.TEXT_JUSTIFY_CENTER);
        var ly = y + dc.getFontHeight(Graphics.FONT_NUMBER_MILD) - 2;
        label(dc, (w * 0.30).toNumber(), ly, ll, DIM);
        label(dc, (w * 0.70).toNumber(), ly, rl, DIM);
        dc.setColor(FAINT, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(w / 2, y + 6, w / 2, ly + 8);
    }

    // ---- screens ------------------------------------------------------------------------------
    public function onUpdate(dc as Dc) as Void {
        var now = Time.now().value();
        var flash = now < _flashUntil;
        dc.setColor(Graphics.COLOR_BLACK, flash ? BAD : Graphics.COLOR_BLACK);
        dc.clear();
        if (_session == null) { drawChecklist(dc); }
        else {
            switch (_page) {
                case PAGE_MIXTURE: drawMixture(dc); break;
                case PAGE_DYNO: drawDyno(dc); break;
                case PAGE_RIDE: drawRide(dc, now); break;
                default: drawEngine(dc); break;
            }
            drawHeader(dc, now);
            drawDots(dc);
        }
        drawFooter(dc, now);
    }

    private function val(key as String) as Number? { return _ecu.hasKey(key) ? (_ecu[key] as Number) : null; }
    private function live() as Number { return ecuFresh() ? TEXT : FAINT; }

    //! Idle: brand mark, four readiness rows in the wide middle band, button hints on the bezel.
    private function drawChecklist(dc as Dc) as Void {
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2;
        if (_icon != null) { dc.drawBitmap(cx - _icon.getWidth() / 2, h * 0.09, _icon); }
        label(dc, cx, (h * 0.25).toNumber(), "M O T O T U N E", ACCENT);

        var phone = phoneConnected();
        var ecu = ecuLive();
        var gps = _gpsQuality >= Position.QUALITY_USABLE;
        var labels = ["PHONE", "ECU", "GPS", "HEART"];
        var age = _lastPosAt == 0 ? "no events" : "q" + _gpsQuality + " · " + (Time.now().value() - _lastPosAt) + "s";
        var values = [phone ? "ready" : "—",
                      ecu ? "live" : "—",
                      _gpsQuality >= Position.QUALITY_GOOD ? "locked" : (gps ? "weak" : "searching · " + age),
                      _hr != null ? _hr.format("%d") + " bpm" : "—"];
        var oks = [phone, ecu, gps, _hr != null];
        var rowH = 34;
        var y = (h * 0.34).toNumber();
        for (var i = 0; i < 4; i++) {
            var ok = oks[i] as Boolean;
            dc.setColor(ok ? GOOD : FAINT, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(w * 0.25, y + rowH / 2, 5);
            dc.setColor(TEXT, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w * 0.31, y + 6, Graphics.FONT_XTINY, labels[i] as String, Graphics.TEXT_JUSTIFY_LEFT);
            dc.setColor(ok ? TEXT : DIM, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w * 0.76, y + 6, Graphics.FONT_XTINY, values[i] as String, Graphics.TEXT_JUSTIFY_RIGHT);
            if (i < 3) { dc.setColor(FAINT, Graphics.COLOR_TRANSPARENT); dc.drawLine(w * 0.24, y + rowH, w * 0.76, y + rowH); }
            y += rowH;
        }
        hint(dc, ANG_START, "start", ecu ? ACCENT : FAINT);
        hint(dc, ANG_BACK, "exit", DIM);
        if (!ecu && (_toast == null || (Time.now().value() - _toastAt) >= 5)) {
            label(dc, cx, (h * 0.86).toNumber(), phone ? "waiting for ECU on the phone" : "connect the phone", DIM);
        }
    }

    private function drawHeader(dc as Dc, now as Number) as Void {
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2;
        var dur = now - _startedAt;
        var t = (dur / 60).format("%d") + ":" + (dur % 60).format("%02d");
        dc.setColor(_paused ? WARN : BAD, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(cx - 38, h * 0.085, 4);
        dc.setColor(TEXT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx - 28, h * 0.085 - dc.getFontHeight(Graphics.FONT_XTINY) / 2, Graphics.FONT_XTINY, (_paused ? "PAUSED " : "REC ") + t, Graphics.TEXT_JUSTIFY_LEFT);
        // button hints that change with state
        if (_paused) { hint(dc, ANG_START, "resume", ACCENT); hint(dc, ANG_UP, "save", GOOD); hint(dc, ANG_BACK, "menu", DIM); }
        else { hint(dc, ANG_START, null, FAINT); hint(dc, ANG_UP, null, ACCENT); }
    }

    private function drawDots(dc as Dc) as Void {
        var w = dc.getWidth(), h = dc.getHeight();
        var x = w / 2 - (PAGE_COUNT - 1) * 7;
        for (var i = 0; i < PAGE_COUNT; i++) {
            dc.setColor(i == _page ? ACCENT : FAINT, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(x + i * 14, h * 0.90, i == _page ? 4 : 3);
        }
    }

    private function drawFooter(dc as Dc, now as Number) as Void {
        var w = dc.getWidth(), h = dc.getHeight();
        var y = (_session == null ? h * 0.86 : h * 0.125).toNumber();
        if (_toast != null && (now - _toastAt) < 5) {
            label(dc, w / 2, y, _toast as String, WARN);
        } else if (_session != null && !ecuFresh()) {
            label(dc, w / 2, y, phoneConnected() ? "waiting for ECU" : "phone not connected", DIM);
        }
    }

    //! Engine: RPM gauge on the bezel with redline, big RPM, gear · TPS.
    private function drawEngine(dc as Dc) as Void {
        var h = dc.getHeight();
        var rpm = val("rpm"), gear = val("gear"), tps = val("tps");
        var frac = rpm == null ? 0.0 : rpm.toFloat() / 12000.0;
        gauge(dc, frac, frac > 0.83 ? BAD : ACCENT, 0.83);
        big(dc, (h * 0.19).toNumber(), rpm == null ? "----" : rpm.format("%d"), live());
        label(dc, dc.getWidth() / 2, (h * 0.455).toNumber(), "R P M", DIM);
        pair(dc, (h * 0.53).toNumber(), (gear == null || gear == 0) ? "N" : gear.format("%d"), "GEAR", tps == null ? "--" : tps.format("%d"), "TPS %", live());
    }

    //! Mixture: AFR gauge 10 (rich) … 16 (lean) with the target as a tick, big AFR, target · BPW.
    private function drawMixture(dc as Dc) as Void {
        var h = dc.getHeight();
        var afr = val("afr"), tgt = val("tgt"), bpw = val("bpw");
        var lean = _ecu.hasKey("lean") && (_ecu["lean"] as Number) == 1;
        var col = live();
        if (ecuFresh() && afr != null) { col = (lean || afr >= 140) ? BAD : (afr <= 115 ? RICH : GOOD); }
        var frac = afr == null ? 0.0 : (afr / 10.0 - 10.0) / 6.0;
        gauge(dc, frac, col, 0.6);                               // beyond 13.6 reads as the danger zone
        if (tgt != null) { var tf = (tgt / 10.0 - 10.0) / 6.0; arc(dc, 225 - (270 * tf).toNumber() - 1, 225 - (270 * tf).toNumber() + 1, TEXT, 14, 3); }
        big(dc, (h * 0.19).toNumber(), afr == null ? "--.-" : (afr / 10.0).format("%.1f"), col);
        label(dc, dc.getWidth() / 2, (h * 0.455).toNumber(), lean ? "L E A N  A T  W O T" : "A F R", lean ? BAD : DIM);
        pair(dc, (h * 0.53).toNumber(), tgt == null ? "--" : (tgt / 10.0).format("%.1f"), "TARGET", bpw == null ? "--" : (bpw / 100.0).format("%.2f"), "BPW ms", live());
    }

    //! Dyno: pulls on this map, the latest revision verdict, map label.
    private function drawDyno(dc as Dc) as Void {
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2;
        var pulls = val("pulls"), cmp = val("cmp"), nsig = val("nsig");
        var sig = cmp != null && nsig != null && nsig > 0;
        if (cmp != null) { gauge(dc, (cmp.abs() / 100.0), !sig ? FAINT : (cmp > 0 ? GOOD : BAD), null); } else { gauge(dc, 0.0, ACCENT, null); }
        big(dc, (h * 0.19).toNumber(), pulls == null ? "0" : pulls.format("%d"), live());
        label(dc, cx, (h * 0.455).toNumber(), "P U L L S", DIM);
        if (cmp != null) {
            dc.setColor(!sig ? DIM : (cmp > 0 ? GOOD : BAD), Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h * 0.53, Graphics.FONT_NUMBER_MILD, (cmp > 0 ? "+" : "") + (cmp / 10.0).format("%.1f") + "%", Graphics.TEXT_JUSTIFY_CENTER);
            label(dc, cx, (h * 0.665).toNumber(), sig ? "VS PREVIOUS MAP — REAL" : "VS PREVIOUS — NOISE", DIM);
        } else {
            dc.setColor(DIM, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h * 0.57, Graphics.FONT_SMALL, "no comparison yet", Graphics.TEXT_JUSTIFY_CENTER);
        }
        label(dc, cx, (h * 0.76).toNumber(), "MAP " + (_ecu.hasKey("map") ? (_ecu["map"] as String).toUpper() : "?") + "  ·  " + _markers + " MARKS", DIM);
    }

    //! Ride: speed gauge to 160 km/h, HR · time.
    private function drawRide(dc as Dc, now as Number) as Void {
        var h = dc.getHeight();
        var spd = val("spd");
        var kmh = (spd != null && ecuFresh()) ? spd : (_speedMps != null ? (_speedMps * 3.6).toNumber() : null);
        gauge(dc, kmh == null ? 0.0 : kmh.toFloat() / 160.0, ACCENT, null);
        big(dc, (h * 0.19).toNumber(), kmh == null ? "--" : kmh.format("%d"), TEXT);
        label(dc, dc.getWidth() / 2, (h * 0.455).toNumber(), (spd != null && ecuFresh()) ? "K M / H  ·  E C U" : "K M / H  ·  G P S", DIM);
        var dur = now - _startedAt;
        pair(dc, (h * 0.53).toNumber(), _hr == null ? "--" : _hr.format("%d"), "BPM", (dur / 60).format("%d") + ":" + (dur % 60).format("%02d"), "TIME", TEXT);
    }
}

//! Swallow transmit results; the watch never blocks on the phone.
class QuietListener extends Communications.ConnectionListener {
    public function initialize() { ConnectionListener.initialize(); }
    public function onComplete() as Void {}
    public function onError() as Void {}
}
