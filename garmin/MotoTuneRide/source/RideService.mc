import Toybox.Application;
import Toybox.Background;
import Toybox.Communications;
import Toybox.Complications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;

//! Runs when the phone sends a message while MotoTune Ride is NOT open: keeps the last ECU snapshot in
//! Storage and refreshes the published "MotoTune AFR" complication, so the watch face shows AFR the way
//! it shows heart rate. Kept tiny — background processes get 64 KB.
(:background)
class RideService extends System.ServiceDelegate {
    public function initialize() { ServiceDelegate.initialize(); }

    public function onPhoneAppMessage(msg as Communications.PhoneAppMessage) as Void {
        var d = msg.data;
        if (d instanceof Dictionary) {
            $.publishSnapshot(d as Dictionary);
            Background.exit(d);
        } else {
            Background.exit(null);
        }
    }
}

//! Shared by the background service and the foreground app: remember the snapshot, update the complication.
(:background)
function publishSnapshot(d as Dictionary) as Void {
    if (d.hasKey("afr")) {
        var afr = d["afr"] as Number;                        // ×10
        Storage.setValue("afr", afr);
        Storage.setValue("rpm", d.hasKey("rpm") ? d["rpm"] as Number : 0);
        Storage.setValue("at", Time.now().value());
        if (Complications has :updateComplication) {
            Complications.updateComplication(0, {:value => (afr / 10.0).format("%.1f"), :shortLabel => "AFR"});
        }
    }
}
