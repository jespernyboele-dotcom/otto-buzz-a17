import android.os.UpdateEngine;
import android.os.UpdateEngineCallback;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * OTTO OTA client (the GSI ships update_engine but no update_engine_client). Run as root:
 *   CLASSPATH=/system/etc/otto/otto_ota.dex app_process / OttoOta apply /data/ota_package/otto_ota.zip
 *   ... OttoOta cancel | reset | cleanup
 * apply: finds payload.bin (stored, not deflated) and payload_properties.txt in the OTA zip, hands the
 * payload to update_engine for the inactive slot and prints progress until it finishes. Exit 0 = the
 * update is written and the other slot is set active for the next boot; anything else = untouched.
 */
public final class OttoOta {
    // update_engine UpdateStatusConstants / ErrorCodeConstants (only the ones printed by name).
    static final String[] STATUS = {"IDLE", "CHECKING", "UPDATE_AVAILABLE", "DOWNLOADING", "VERIFYING",
            "FINALIZING", "UPDATED_NEED_REBOOT", "REPORTING_ERROR", "ATTEMPTING_ROLLBACK", "DISABLED",
            "NEED_PERMISSION_TO_UPDATE", "CLEANUP_PREVIOUS_UPDATE"};

    public static void main(String[] args) throws Exception {
        if (args.length == 0) { usage(); return; }
        UpdateEngine engine = new UpdateEngine();
        switch (args[0]) {
            case "apply": if (args.length < 2) { usage(); return; } System.exit(apply(engine, args[1])); break;
            case "cancel": engine.cancel(); System.out.println("cancelled"); break;
            case "reset": engine.resetStatus(); System.out.println("reset"); break;
            case "cleanup": engine.cleanupAppliedPayload(); System.out.println("cleanup requested"); break;
            default: usage();
        }
    }

    static int apply(UpdateEngine engine, String path) throws Exception {
        long offset = -1, size = -1;
        List<String> headers = new ArrayList<>();
        try (ZipFile zip = new ZipFile(path)) {
            ZipEntry payload = zip.getEntry("payload.bin");
            ZipEntry props = zip.getEntry("payload_properties.txt");
            if (payload == null || props == null) { System.err.println("not an A/B OTA zip: " + path); return 2; }
            if (payload.getMethod() != ZipEntry.STORED) { System.err.println("payload.bin must be stored, not deflated"); return 2; }
            size = payload.getCompressedSize();
            offset = dataOffset(path, zip, payload);
            try (BufferedReader r = new BufferedReader(new InputStreamReader(zip.getInputStream(props)))) {
                for (String l; (l = r.readLine()) != null; ) if (!l.trim().isEmpty()) headers.add(l.trim());
            }
        }
        System.out.println("payload offset=" + offset + " size=" + size + " headers=" + headers.size());
        CountDownLatch done = new CountDownLatch(1);
        int[] result = {-1};
        engine.bind(new UpdateEngineCallback() {
            int last = -2;
            @Override public void onStatusUpdate(int status, float percent) {
                int pct = (int) (percent * 100);
                if (status * 1000 + pct != last) {
                    last = status * 1000 + pct;
                    System.out.println("status " + (status >= 0 && status < STATUS.length ? STATUS[status] : status) + " " + pct + "%");
                }
            }
            @Override public void onPayloadApplicationComplete(int errorCode) {
                result[0] = errorCode;
                done.countDown();
            }
        });
        engine.applyPayload("file://" + path, offset, size, headers.toArray(new String[0]));
        done.await();
        System.out.println(result[0] == 0 ? "DONE: reboot to try the new slot (falls back by itself if it fails)"
                : "FAILED error=" + result[0] + " (see logcat -s update_engine)");
        return result[0] == 0 ? 0 : 1;
    }

    /** Offset of an entry's data: its local header offset + 30 + name length + extra length. */
    static long dataOffset(String path, ZipFile zip, ZipEntry entry) throws Exception {
        try (java.io.RandomAccessFile f = new java.io.RandomAccessFile(path, "r")) {
            // Walk the local headers in file order (the OTA zip is small: a handful of entries).
            long pos = 0;
            byte[] h = new byte[30];
            while (pos + 30 <= f.length()) {
                f.seek(pos);
                f.readFully(h);
                if (le32(h, 0) != 0x04034b50) break;
                int nameLen = le16(h, 26), extraLen = le16(h, 28);
                byte[] name = new byte[nameLen];
                f.readFully(name);
                long data = pos + 30 + nameLen + extraLen;
                long csize = le32(h, 18) & 0xffffffffL;
                if (new String(name, "UTF-8").equals(entry.getName())) return data;
                if ((le16(h, 6) & 8) != 0) csize = zip.getEntry(new String(name, "UTF-8")).getCompressedSize();
                pos = data + csize;
            }
        }
        throw new IllegalStateException("payload.bin local header not found");
    }

    static int le16(byte[] b, int o) { return (b[o] & 0xff) | (b[o + 1] & 0xff) << 8; }
    static int le32(byte[] b, int o) { return le16(b, o) | le16(b, o + 2) << 16; }

    static void usage() {
        System.out.println("OttoOta apply <ota.zip> | cancel | reset | cleanup");
    }
}
