package android.os;
// Compile-time stub only; the real class is in framework.jar on OTTO and is not packed.
public class UpdateEngine {
    public UpdateEngine() {}
    public boolean bind(UpdateEngineCallback callback) { return false; }
    public void applyPayload(String url, long offset, long size, String[] headerKeyValuePairs) {}
    public void cancel() {}
    public void resetStatus() {}
    public void cleanupAppliedPayload() {}
}
