import Toybox.Activity;
import Toybox.ActivityRecording;
import Toybox.Attention;
import Toybox.Communications;
import Toybox.FitContributor;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Position;
import Toybox.Sensor;
import Toybox.System;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

//! Riding screens. Follows the watch's own activity conventions so a rider's fingers already know it:
//!   START = start · pause (pause shows Resume / Save / Discard)   BACK while recording = marker (lap)
//!   UP / DOWN / swipe = pages: Engine · Mixture · Dyno · Ride        before start: a readiness checklist
class RideView extends WatchUi.View {
    enum { PAGE_ENGINE, PAGE_MIXTURE, PAGE_DYNO, PAGE_RIDE, PAGE_COUNT }

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
    private var _startedAt as Number = 0;
    private var _maxRpm as Number = 0;
    private var _toast as String? = null;
    private var _toastAt as Number = 0;
    private var _ticks as Number = 0;
    private var _timer as Timer.Timer = new Timer.Timer();
    private var _fRpm as Field?;
    private var _fAfr as Field?;
    private var _fTps as Field?;
    private var _fGear as Field?;

    public function initialize() { View.initialize(); }

    public function onShow() as Void {
        Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
        Sensor.enableSensorEvents(method(:onSensor));
        _timer.start(method(:tick), 1000, true);
    }
    public function onHide() as Void { _timer.stop(); Sensor.enableSensorEvents(null); }
    public function onSensor(info as Sensor.Info) as Void { _hr = info.heartRate; }
    public function onPosition(info as Position.Info) as Void { _gpsQuality = info.accuracy; _speedMps = info.speed; }

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

    //! Once a second: redraw (timer, fading); every 10 s tell the phone our HR — only with a phone connected.
    public function tick() as Void {
        _ticks += 1;
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

    public function startRecording() as Void {
        if (!(Toybox has :ActivityRecording)) { toast("no FIT support"); return; }
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

    //! Save or discard; returns the summary line for the SummaryView.
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

    //! Marker = lap in the FIT + timestamped message to the phone. BACK button while recording.
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

    // ---- drawing ----------------------------------------------------------------------------
    public function onUpdate(dc as Dc) as Void {
        var now = Time.now().value();
        var flash = now < _flashUntil;
        dc.setColor(Graphics.COLOR_BLACK, flash ? Graphics.COLOR_RED : Graphics.COLOR_BLACK);
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
    private function live() as Graphics.ColorType { return ecuFresh() ? Graphics.COLOR_WHITE : Graphics.COLOR_DK_GRAY; }

    //! Before the ride: is everything that feeds the screen actually there?
    //! Rows sit in the widest band of the round screen; values are short so they never reach the labels.
    private function drawChecklist(dc as Dc) as Void {
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.12, Graphics.FONT_SMALL, "MotoTune Ride", Graphics.TEXT_JUSTIFY_CENTER);
        var phone = phoneConnected();
        var ecu = ecuFresh() && _ecu.hasKey("ecu") && (_ecu["ecu"] as Number) == 1;
        var gps = _gpsQuality >= Position.QUALITY_USABLE;
        var labels = ["Phone", "ECU", "GPS", "HR"];
        var values = [phone ? "OK" : "no",
                      ecu ? "live" : "no",
                      _gpsQuality >= Position.QUALITY_GOOD ? "OK" : (gps ? "weak" : "search"),
                      _hr != null ? _hr.format("%d") : "--"];
        var oks = [phone, ecu, gps, _hr != null];
        var font = Graphics.FONT_SMALL;
        var lh = dc.getFontHeight(font) + 4;
        var y = h * 0.50 - lh * 2;                       // four rows centred on the middle of the screen
        for (var i = 0; i < 4; i++) {
            var ok = oks[i] as Boolean;
            dc.setColor(ok ? Graphics.COLOR_GREEN : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(w * 0.24, y + lh / 2, 6);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w * 0.31, y, font, labels[i] as String, Graphics.TEXT_JUSTIFY_LEFT);
            dc.setColor(ok ? Graphics.COLOR_GREEN : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w * 0.78, y, font, values[i] as String, Graphics.TEXT_JUSTIFY_RIGHT);
            y += lh;
        }
        dc.setColor(phone && gps ? Graphics.COLOR_GREEN : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.74, Graphics.FONT_SMALL, "START to ride", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.84, Graphics.FONT_XTINY, "UP mark · DOWN page · BACK exit", Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function drawHeader(dc as Dc, now as Number) as Void {
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2;
        var dur = now - _startedAt;
        var t = (dur / 60).format("%d") + ":" + (dur % 60).format("%02d");
        var gps = _gpsQuality >= Position.QUALITY_GOOD ? "GPS" : (_gpsQuality >= Position.QUALITY_USABLE ? "gps" : "GPS…");
        dc.setColor(_paused ? Graphics.COLOR_YELLOW : Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.05, Graphics.FONT_XTINY, (_paused ? "PAUSED  " : "REC  ") + t + "   " + gps + (_hr != null ? "   " + _hr + " bpm" : ""), Graphics.TEXT_JUSTIFY_CENTER);
        if (_paused && _toast == null) {
            dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h * 0.85, Graphics.FONT_XTINY, "START resume · UP save · BACK menu", Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    private function drawDots(dc as Dc) as Void {
        var w = dc.getWidth(), h = dc.getHeight();
        var x = w / 2 - (PAGE_COUNT - 1) * 7;
        for (var i = 0; i < PAGE_COUNT; i++) {
            dc.setColor(i == _page ? Graphics.COLOR_WHITE : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(x + i * 14, h * 0.94, i == _page ? 4 : 3);
        }
    }

    private function drawFooter(dc as Dc, now as Number) as Void {
        if (_toast != null && (now - _toastAt) < 5) {
            dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
            dc.drawText(dc.getWidth() / 2, dc.getHeight() * 0.85, Graphics.FONT_XTINY, _toast as String, Graphics.TEXT_JUSTIFY_CENTER);
        } else if (_session != null && !ecuFresh()) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(dc.getWidth() / 2, dc.getHeight() * 0.85, Graphics.FONT_XTINY, phoneConnected() ? "waiting for ECU data…" : "phone not connected", Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    //! Page 1: RPM huge, gear, TPS bar.
    private function drawEngine(dc as Dc) as Void {
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2;
        var rpm = val("rpm"), gear = val("gear"), tps = val("tps");
        dc.setColor(live(), Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.17, Graphics.FONT_NUMBER_THAI_HOT, rpm == null ? "----" : rpm.format("%d"), Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.47, Graphics.FONT_XTINY, "RPM", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(live(), Graphics.COLOR_TRANSPARENT);
        dc.drawText(w * 0.30, h * 0.55, Graphics.FONT_NUMBER_MEDIUM, (gear == null || gear == 0) ? "N" : gear.format("%d"), Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(w * 0.70, h * 0.55, Graphics.FONT_NUMBER_MEDIUM, tps == null ? "--" : tps.format("%d"), Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w * 0.30, h * 0.70, Graphics.FONT_XTINY, "GEAR", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(w * 0.70, h * 0.70, Graphics.FONT_XTINY, "TPS %", Graphics.TEXT_JUSTIFY_CENTER);
        var bx = w * 0.15, by = h * 0.78, bw = w * 0.70, bh = 10;
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(bx, by, bw, bh, 5);
        if (tps != null) {
            var pct = tps > 100 ? 100 : tps;
            dc.setColor(pct >= 90 ? Graphics.COLOR_ORANGE : Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(bx, by, bw * pct / 100.0, bh, 5);
        }
    }

    //! Page 2: AFR big and colour-coded, target, BPW.
    private function drawMixture(dc as Dc) as Void {
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2;
        var afr = val("afr"), tgt = val("tgt"), bpw = val("bpw");
        var lean = _ecu.hasKey("lean") && (_ecu["lean"] as Number) == 1;
        var col = live();
        if (ecuFresh() && afr != null) {
            if (lean || afr >= 140) { col = Graphics.COLOR_RED; }
            else if (afr <= 115) { col = Graphics.COLOR_BLUE; }
            else { col = Graphics.COLOR_GREEN; }
        }
        dc.setColor(col, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.17, Graphics.FONT_NUMBER_THAI_HOT, afr == null ? "--.-" : (afr / 10.0).format("%.1f"), Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.47, Graphics.FONT_XTINY, lean ? "AFR — LEAN AT WOT" : "AFR", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(live(), Graphics.COLOR_TRANSPARENT);
        dc.drawText(w * 0.30, h * 0.55, Graphics.FONT_NUMBER_MEDIUM, tgt == null ? "--" : (tgt / 10.0).format("%.1f"), Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(w * 0.70, h * 0.55, Graphics.FONT_NUMBER_MEDIUM, bpw == null ? "--" : (bpw / 100.0).format("%.2f"), Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w * 0.30, h * 0.70, Graphics.FONT_XTINY, "TARGET", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(w * 0.70, h * 0.70, Graphics.FONT_XTINY, "BPW ms", Graphics.TEXT_JUSTIFY_CENTER);
    }

    //! Page 3: the tuning loop at a glance — pulls, latest revision verdict, map, markers.
    private function drawDyno(dc as Dc) as Void {
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2;
        var pulls = val("pulls"), cmp = val("cmp"), nsig = val("nsig");
        dc.setColor(live(), Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.17, Graphics.FONT_NUMBER_THAI_HOT, pulls == null ? "0" : pulls.format("%d"), Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.47, Graphics.FONT_XTINY, "PULLS THIS MAP", Graphics.TEXT_JUSTIFY_CENTER);
        if (cmp != null) {
            var sig = nsig != null && nsig > 0;
            dc.setColor(!sig ? Graphics.COLOR_LT_GRAY : (cmp > 0 ? Graphics.COLOR_GREEN : Graphics.COLOR_RED), Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h * 0.55, Graphics.FONT_NUMBER_MEDIUM, (cmp > 0 ? "+" : "") + (cmp / 10.0).format("%.1f") + "%", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h * 0.70, Graphics.FONT_XTINY, sig ? "vs previous map — real" : "vs previous — within noise", Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h * 0.60, Graphics.FONT_SMALL, "no comparison yet", Graphics.TEXT_JUSTIFY_CENTER);
        }
        dc.drawText(cx, h * 0.78, Graphics.FONT_XTINY, "map " + (_ecu.hasKey("map") ? _ecu["map"] : "?") + "  ·  " + _markers + " marks", Graphics.TEXT_JUSTIFY_CENTER);
    }

    //! Page 4: the ride itself — speed (ECU, else GPS), HR, time.
    private function drawRide(dc as Dc, now as Number) as Void {
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2;
        var spd = val("spd");
        var kmh = (spd != null && ecuFresh()) ? spd : (_speedMps != null ? (_speedMps * 3.6).toNumber() : null);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.17, Graphics.FONT_NUMBER_THAI_HOT, kmh == null ? "--" : kmh.format("%d"), Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.47, Graphics.FONT_XTINY, (spd != null && ecuFresh()) ? "KM/H (ECU)" : "KM/H (GPS)", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w * 0.30, h * 0.55, Graphics.FONT_NUMBER_MEDIUM, _hr == null ? "--" : _hr.format("%d"), Graphics.TEXT_JUSTIFY_CENTER);
        var dur = now - _startedAt;
        dc.drawText(w * 0.70, h * 0.55, Graphics.FONT_NUMBER_MEDIUM, (dur / 60).format("%d") + ":" + (dur % 60).format("%02d"), Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w * 0.30, h * 0.70, Graphics.FONT_XTINY, "HR", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(w * 0.70, h * 0.70, Graphics.FONT_XTINY, "TIME", Graphics.TEXT_JUSTIFY_CENTER);
    }
}

//! Swallow transmit results; the watch never blocks on the phone.
class QuietListener extends Communications.ConnectionListener {
    public function initialize() { ConnectionListener.initialize(); }
    public function onComplete() as Void {}
    public function onError() as Void {}
}
