package cordova.wsserver;

import java.net.Inet4Address;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.SocketException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Enumeration;
import java.util.List;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.PluginResult;
import org.apache.cordova.PluginResult.Status;
import org.java_websocket.drafts.Draft;
import org.java_websocket.drafts.Draft_6455;
import org.java_websocket.extensions.IExtension;
import org.java_websocket.protocols.IProtocol;
import org.java_websocket.protocols.Protocol;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import android.util.Log;

public class WebSocketServerPlugin extends CordovaPlugin {

    public static final String TAG = "WebSocketServer";

    private volatile WebSocketServerImpl wsserver = null;

    public static final String ACTION_GET_INTERFACES = "getInterfaces";
    public static final String ACTION_START = "start";
    public static final String ACTION_STOP = "stop";
    public static final String ACTION_SEND = "send";
    public static final String ACTION_SEND_BINARY = "send_binary";
    public static final String ACTION_CLOSE = "close";

    private static final int STOP_TIMEOUT_MS = 2000;

    @Override
    protected void pluginInitialize() {
        Log.v(TAG, "Initialized");
    }

    @Override
    public void onReset() {
        // Page reload or navigation: the JS that started the server is gone, and a new
        // page calling start() would otherwise get "Server already running."
        stopServerInBackground();
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
        // onDestroy runs on the UI thread; stopping inline could block it (ANR)
        stopServerInBackground();
    }

    private void stopServerInBackground() {
        final WebSocketServerImpl oldServer = wsserver;
        wsserver = null;
        if (oldServer != null) {
            cordova.getThreadPool().execute(() -> {
                try {
                    oldServer.stop(STOP_TIMEOUT_MS);
                } catch (InterruptedException e) {
                    Log.e(TAG, e.getMessage(), e);
                }
            });
        }
    }

    @Override
    public boolean execute(String action, JSONArray args, final CallbackContext callbackContext) {

        if (wsserver != null && wsserver.failed) {
            wsserver = null;
        }

        if (ACTION_GET_INTERFACES.equals(action)) {

            cordova.getThreadPool().execute(() -> {
                try {
                    JSONObject addresses = getInterfaces();

                    Log.d(TAG, "Addresses: " + addresses);

                    PluginResult result = new PluginResult(Status.OK, addresses);
                    callbackContext.sendPluginResult(result);

                } catch (JSONException | SocketException e) {
                    Log.e(TAG, e.getMessage(), e);
                    callbackContext.error("Error: " + e.getMessage());
                }
            });

        } else if (ACTION_START.equals(action)) {

            if (wsserver != null) {
                callbackContext.error("Server already running.");
                return true;
            }

            final int port = args.optInt(0);

            List<String> origins;
            List<String> protocols;
            try {
                origins = jsonArrayToArrayList(args.optJSONArray(1));
            } catch (JSONException e) {
                Log.e(TAG, e.getMessage(), e);
                callbackContext.error("Origins option error");
                return true;
            }
            try {
                protocols = jsonArrayToArrayList(args.optJSONArray(2));
            } catch (JSONException e) {
                Log.e(TAG, e.getMessage(), e);
                callbackContext.error("Protocols option error");
                return true;
            }

            // Created and assigned on this (the JS bridge) thread, so an immediately following
            // start() or stop() sees it. Neither the constructor nor start() blocks: binding
            // happens on the server's own thread, which reports onStart/onError.
            WebSocketServerImpl newServer;
            try {
                if (protocols != null) {
                    // One draft knowing every protocol: it picks the first server protocol
                    // the client requested.
                    ArrayList<IProtocol> knownProtocols = new ArrayList<>();
                    for (String protocol : protocols) {
                        knownProtocols.add(new Protocol(protocol));
                    }
                    Draft draft = new Draft_6455(Collections.<IExtension> emptyList(), knownProtocols);
                    newServer = new WebSocketServerImpl(port, Collections.singletonList(draft));
                } else {
                    newServer = new WebSocketServerImpl(port);
                }
            } catch (IllegalArgumentException e) {
                Log.e(TAG, e.getMessage(), e);
                callbackContext.error("Port number error");
                return true;
            }

            newServer.setCallbackContext(callbackContext);
            if (origins != null) {
                newServer.setOrigins(origins);
            }
            if (!args.isNull(3)) {
                newServer.setTcpNoDelay(args.optBoolean(3));
            }
            // allow an immediate restart on the same port (socket may still be in TIME_WAIT)
            newServer.setReuseAddr(true);

            wsserver = newServer;
            newServer.start();

        } else if (ACTION_STOP.equals(action)) {

            if (wsserver == null) {
                callbackContext.error("Server is not running.");
                return true;
            }

            final WebSocketServerImpl oldServer = wsserver;
            wsserver = null;

            cordova.getThreadPool().execute(() -> {
                try {
                    oldServer.stop(STOP_TIMEOUT_MS);
                } catch (InterruptedException e) {
                    Log.e(TAG, e.getMessage(), e);
                    callbackContext.error("Error: " + e.getMessage());
                    return;
                }

                try {
                    JSONObject status = new JSONObject();
                    status.put("addr", oldServer.getHostAddress());
                    status.put("port", oldServer.getPort());

                    Log.d(TAG, "stop result: " + status.toString());
                    callbackContext.success(status);

                } catch (JSONException e) {
                    Log.e(TAG, e.getMessage(), e);
                }
            });

        } else if (ACTION_SEND.equals(action) || ACTION_SEND_BINARY.equals(action)) {

            // optString() turns a JSON null into the string "null", so check isNull() first
            if (!args.isNull(0) && !args.isNull(1)) {
                final String uuid = args.optString(0);
                final String msg = args.optString(1);
                // WebSocket.send() only queues the frame, so call it directly: dispatching to
                // the (multi-threaded) Cordova pool could reorder consecutive messages.
                WebSocketServerImpl server = wsserver;
                if (server != null) {
                    server.send(uuid, msg, ACTION_SEND_BINARY.equals(action));
                }
            } else {
                callbackContext.error("UUID or msg not specified.");
                return true;
            }

        } else if (ACTION_CLOSE.equals(action)) {

            final int code = args.optInt(1, -1);
            // close(conn, code) without a reason arrives as null, which optString() would send as "null"
            final String reason = args.isNull(2) ? "" : args.optString(2);

            if (!args.isNull(0)) {
                final String uuid = args.optString(0);
                // Same thread as send() so a close is ordered after any preceding sends.
                WebSocketServerImpl server = wsserver;
                if (server != null) {
                    server.close(uuid, code, reason);
                }
            } else {
                callbackContext.error("UUID not specified.");
                return true;
            }

        } else {
            // returning false makes Cordova report INVALID_ACTION to the caller
            Log.w(TAG, "Invalid action: " + action);
            return false;
        }

        return true;
    }

    public static ArrayList<String> jsonArrayToArrayList(JSONArray jsonArray) throws JSONException {
        ArrayList<String> list = null;
        if (jsonArray != null && jsonArray.length() > 0) {
            list = new ArrayList<>();
            for (int i = 0; i < jsonArray.length(); i++) {
                list.add(jsonArray.get(i).toString());
            }
        }
        return list;
    }

    // return IP4 & IP6 addresses
    public static JSONObject getInterfaces() throws JSONException, SocketException {
        JSONObject obj = new JSONObject();
        JSONObject intfobj;
        JSONArray ipv4Addresses;
        JSONArray ipv6Addresses;

        // null when the device has no network interfaces
        Enumeration<NetworkInterface> networkInterfaces = NetworkInterface.getNetworkInterfaces();
        if (networkInterfaces == null) {
            return obj;
        }
        List<NetworkInterface> intfs = Collections.list(networkInterfaces);
        for (NetworkInterface intf : intfs) {
            if (!intf.isLoopback()) {
                intfobj = new JSONObject();
                ipv4Addresses = new JSONArray();
                ipv6Addresses = new JSONArray();

                List<InetAddress> addrs = Collections.list(intf.getInetAddresses());
                for (InetAddress addr : addrs) {
                    if (!addr.isLoopbackAddress()) {
                        if (addr instanceof Inet6Address) {
                            ipv6Addresses.put(addr.getHostAddress());
                        } else if (addr instanceof Inet4Address) {
                            ipv4Addresses.put(addr.getHostAddress());
                        }
                    }
                }

                if ((ipv4Addresses.length() > 0) || (ipv6Addresses.length() > 0)) {
                    intfobj.put("ipv4Addresses", ipv4Addresses);
                    intfobj.put("ipv6Addresses", ipv6Addresses);
                    obj.put(intf.getName(), intfobj);
                }
            }
        }

        return obj;
    }

}
