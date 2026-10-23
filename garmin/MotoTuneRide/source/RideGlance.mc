import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Time;
import Toybox.WatchUi;

//! One swipe from the watch face: the last AFR and RPM the phone sent, and how old they are.
(:glance)
class RideGlance extends WatchUi.GlanceView {
    public function initialize() { GlanceView.initialize(); }

    public function onUpdate(dc as Dc) as Void {
        var afr = Storage.getValue("afr") as Number?;
        var rpm = Storage.getValue("rpm") as Number?;
        var at = Storage.getValue("at") as Number?;
        var age = at == null ? null : Time.now().value() - at;
        var h = dc.getHeight();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(0, 0, Graphics.FONT_GLANCE, "MotoTune", Graphics.TEXT_JUSTIFY_LEFT);
        var fresh = age != null && age < 15;
        dc.setColor(fresh ? 0x25E0D0 : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        var line = afr == null ? "AFR  --.-" : "AFR  " + (afr / 10.0).format("%.1f") + (rpm != null && rpm > 0 ? "   " + rpm + " rpm" : "");
        dc.drawText(0, h / 2, Graphics.FONT_GLANCE_NUMBER, line, Graphics.TEXT_JUSTIFY_LEFT);
        if (age != null && !fresh) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(dc.getWidth(), 0, Graphics.FONT_GLANCE, age < 3600 ? (age / 60) + " min ago" : "old", Graphics.TEXT_JUSTIFY_RIGHT);
        }
    }
}
