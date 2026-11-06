package android.os;
// Compile-time stub only; the real class is in framework.jar on OTTO and is not packed.
public abstract class UpdateEngineCallback {
    public abstract void onStatusUpdate(int status, float percent);
    public abstract void onPayloadApplicationComplete(int errorCode);
}
