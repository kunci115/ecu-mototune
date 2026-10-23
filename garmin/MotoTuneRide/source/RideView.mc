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

//! The riding screen: big RPM, AFR vs target, gear, pull counter, recording state.
//! Owns the FIT session and the developer fields that put ECU data into the FIT file.
class RideView extends WatchUi.View {
    private var _session as Session?;
    private var _ecu as Dictionary = {};          // latest snapshot from the phone
    private var _lastEcuAt as Number = 0;         // seconds, to grey out stale data
    private var _wasLean as Boolean = false;
    private var _markers as Number = 0;
    private var _hr as Number? = null;
    private var _gpsQuality as Number = 0;
    private var _toast as String? = null;         // last action / error, shown in the footer for a few seconds
    private var _toastAt as Number = 0;
    private var _timer as Timer.Timer = new Timer.Timer();
    // FIT developer fields (record message): what the ECU was doing at every second of the ride
    private var _fRpm as Field?;
    private var _fAfr as Field?;
    private var _fTps as Field?;
    private var _fGear as Field?;

    public function initialize() {
        View.initialize();
    }

    public function onShow() as Void {
        Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
        Sensor.enableSensorEvents(method(:onSensor));
        _timer.start(method(:tick), 10000, true);     // every 10 s: tell the phone our HR
    }

    public function onHide() as Void {
        _timer.stop();
        Sensor.enableSensorEvents(null);
    }

    public function onSensor(info as Sensor.Info) as Void {
        _hr = info.heartRate;
    }

    public function onPosition(info as Position.Info) as Void {
        _gpsQuality = info.accuracy;
    }

    public function onEcu(d as Dictionary) as Void {
        _ecu = d;
        _lastEcuAt = Time.now().value();
        var lean = d.hasKey("lean") && (d["lean"] as Number) == 1;
        if (lean && !_wasLean) { buzz(2); }       // lean at full throttle: two long pulses
        _wasLean = lean;
        // write ECU values into the FIT record so the ride file carries them next to GPS/baro/HR
        if (_session != null && _session.isRecording()) {
            if (_fRpm != null && d.hasKey("rpm")) { _fRpm.setData(d["rpm"] as Number); }
            if (_fAfr != null && d.hasKey("afr")) { _fAfr.setData(d["afr"] as Number); }
            if (_fTps != null && d.hasKey("tps")) { _fTps.setData(d["tps"] as Number); }
            if (_fGear != null && d.hasKey("gear")) { _fGear.setData(d["gear"] as Number); }
        }
    }

    //! Periodic watch → phone: heart rate (for the drowsiness score) and recording state.
    //! Only when a phone is actually connected — otherwise the radio (and the simulator's ADB prompt) stays quiet.
    public function tick() as Void {
        if (!phoneConnected()) { return; }
        var msg = {"hr" => (_hr == null ? 0 : _hr), "rec" => isRecording() ? 1 : 0};
        Communications.transmit(msg, null, new $.QuietListener());
    }

    private function phoneConnected() as Boolean {
        var ds = System.getDeviceSettings();
        return ds != null && ds.phoneConnected;
    }

    // ---- recording ------------------------------------------------------------------------

    public function isRecording() as Boolean {
        return _session != null && _session.isRecording();
    }

    public function startRecording() as Void {
        if (!(Toybox has :ActivityRecording)) { toast("no FIT support"); return; }
        try {
            var sport = Activity.SPORT_CYCLING;
            if (Activity has :SPORT_MOTORCYCLING) { sport = Activity.SPORT_MOTORCYCLING; }
            var s = ActivityRecording.createSession({:name => "MotoTune Ride", :sport => sport});
            _session = s;
            // developer fields are optional: if the firmware refuses them, still record the ride
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
            buzz(1);
            if (_toast == null) { toast("recording"); }
        } catch (e) {
            _session = null;
            toast("start failed: " + e.getErrorMessage());
        }
        WatchUi.requestUpdate();
    }

    public function stopRecording(save as Boolean) as Void {
        var s = _session;
        if (s == null) { toast("nothing to stop"); WatchUi.requestUpdate(); return; }
        try {
            if (s.isRecording()) { s.stop(); }
            if (save) { s.save(); toast("saved"); } else { s.discard(); toast("discarded"); }
        } catch (e) {
            toast("stop failed: " + e.getErrorMessage());
        }
        _session = null;
        _fRpm = null; _fAfr = null; _fTps = null; _fGear = null;
        WatchUi.requestUpdate();
    }

    public function toastResume() as Void { toast("resumed"); WatchUi.requestUpdate(); }

    private function toast(msg as String) as Void {
        _toast = msg; _toastAt = Time.now().value();
        System.println("MotoTune: " + msg);
    }

    //! A "feel" marker: lap in the FIT + a timestamped message to the phone ("flat spot here").
    public function mark() as Void {
        _markers += 1;
        var s = _session;
        if (s != null && s.isRecording()) { s.addLap(); }
        if (phoneConnected()) {
            var msg = {"mark" => Time.now().value(), "hr" => (_hr == null ? 0 : _hr), "n" => _markers};
            Communications.transmit(msg, null, new $.QuietListener());
        }
        buzz(1);
        WatchUi.requestUpdate();
    }

    private function buzz(times as Number) as Void {
        if (Attention has :vibrate) {
            var profile = [] as Array<Attention.VibeProfile>;
            for (var i = 0; i < times; i++) {
                profile.add(new Attention.VibeProfile(80, 300));
                profile.add(new Attention.VibeProfile(0, 150));
            }
            Attention.vibrate(profile);
        }
    }

    // ---- drawing --------------------------------------------------------------------------

    public function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2;
        var fresh = (Time.now().value() - _lastEcuAt) < 5;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        // header: state + GPS + HR
        var state = isRecording() ? "REC" : "READY";
        dc.setColor(isRecording() ? Graphics.COLOR_RED : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        var gps = _gpsQuality >= Position.QUALITY_GOOD ? "GPS ok" : (_gpsQuality >= Position.QUALITY_USABLE ? "GPS weak" : "GPS…");
        dc.drawText(cx, h * 0.07, Graphics.FONT_XTINY, state + " · " + gps + (_hr != null ? " · " + _hr + " bpm" : ""), Graphics.TEXT_JUSTIFY_CENTER);

        // RPM, big
        var rpm = _ecu.hasKey("rpm") ? (_ecu["rpm"] as Number) : null;
        dc.setColor(fresh ? Graphics.COLOR_WHITE : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.22, Graphics.FONT_NUMBER_THAI_HOT, rpm == null ? "----" : rpm.format("%d"), Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.50, Graphics.FONT_XTINY, "RPM", Graphics.TEXT_JUSTIFY_CENTER);

        // AFR vs target, gear, TPS
        var afr = _ecu.hasKey("afr") ? (_ecu["afr"] as Number) / 10.0 : null;
        var tgt = _ecu.hasKey("tgt") ? (_ecu["tgt"] as Number) / 10.0 : null;
        var lean = _ecu.hasKey("lean") && (_ecu["lean"] as Number) == 1;
        dc.setColor(lean ? Graphics.COLOR_RED : (fresh ? Graphics.COLOR_WHITE : Graphics.COLOR_DK_GRAY), Graphics.COLOR_TRANSPARENT);
        var afrText = (afr == null ? "--.-" : afr.format("%.1f")) + (tgt == null ? "" : " / " + tgt.format("%.1f"));
        dc.drawText(cx, h * 0.57, Graphics.FONT_MEDIUM, afrText, Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.69, Graphics.FONT_XTINY, lean ? "AFR  LEAN!" : "AFR / target", Graphics.TEXT_JUSTIFY_CENTER);

        var gear = _ecu.hasKey("gear") ? "G" + (_ecu["gear"] as Number) : "G-";
        var tps = _ecu.hasKey("tps") ? (_ecu["tps"] as Number) + "%" : "--%";
        var pulls = _ecu.hasKey("pulls") ? "pull " + (_ecu["pulls"] as Number) : "pull 0";
        dc.setColor(fresh ? Graphics.COLOR_WHITE : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.76, Graphics.FONT_SMALL, gear + "   " + tps + "   " + pulls, Graphics.TEXT_JUSTIFY_CENTER);

        // footer: map label + markers, or the no-phone hint
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        var foot = fresh ? ("map " + (_ecu.hasKey("map") ? _ecu["map"] : "?") + (_markers > 0 ? "  ·  " + _markers + " marks" : ""))
                         : "waiting for phone…";
        if (_toast != null && (Time.now().value() - _toastAt) < 6) {
            dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
            foot = _toast as String;
        }
        dc.drawText(cx, h * 0.86, Graphics.FONT_XTINY, foot, Graphics.TEXT_JUSTIFY_CENTER);
    }
}

//! Swallow transmit results; the watch never blocks on the phone.
class QuietListener extends Communications.ConnectionListener {
    public function initialize() { ConnectionListener.initialize(); }
    public function onComplete() as Void {}
    public function onError() as Void {}
}
