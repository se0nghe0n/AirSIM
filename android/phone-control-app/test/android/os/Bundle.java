package android.os;
public final class Bundle {
    private final java.util.Map<String, Object> values = new java.util.HashMap<>();
    public void putString(String key, String value) { values.put(key, value); }
    public String getString(String key) { return (String) values.get(key); }
    public void putBundle(String key, Bundle value) { values.put(key, value); }
    public Bundle getBundle(String key) { return (Bundle) values.get(key); }
    public void putParcelable(String key, Object value) { values.put(key, value); }
    public Object getParcelable(String key) { return values.get(key); }
    public boolean containsKey(String key) { return values.containsKey(key); }
}
