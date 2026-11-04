package cordova.wsserver;

import android.util.Log;
import android.util.Base64;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.PluginResult;
import org.java_websocket.WebSocket;
import org.java_websocket.drafts.Draft;
import org.java_websocket.exceptions.InvalidDataException;
import org.java_websocket.framing.CloseFrame;
import org.java_websocket.handshake.ClientHandshake;
import org.java_websocket.handshake.ServerHandshakeBuilder;
import org.java_websocket.server.WebSocketServer;
import org.json.JSONException;
import org.json.JSONObject;

import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

public class WebSocketServerImpl extends WebSocketServer {

    private final int[] notCleanCodes = new int[] { CloseFrame.ABNORMAL_CLOSE, CloseFrame.BUGGYCLOSE,
            CloseFrame.EXTENSION, CloseFrame.FLASHPOLICY, CloseFrame.GOING_AWAY, CloseFrame.NEVER_CONNECTED,
            CloseFrame.NO_UTF8, CloseFrame.NOCODE, CloseFrame.POLICY_VALIDATION, CloseFrame.PROTOCOL_ERROR,
            CloseFrame.REFUSE, CloseFrame.TLS_ERROR, CloseFrame.TOOBIG, CloseFrame.UNEXPECTED_CONDITION,
            CloseFrame.SERVICE_RESTART, CloseFrame.TRY_AGAIN_LATER, CloseFrame.BAD_GATEWAY };

    public volatile boolean failed = false;

    private volatile CallbackContext callbackContext;

    private List<String> origins;

    // Accessed from Java-WebSocket worker threads and from the plugin's command threads.
    private final Map<String, WebSocket> UUIDSockets = new ConcurrentHashMap<>();

    private final Map<WebSocket, String> socketsUUID = new ConcurrentHashMap<>();

    public WebSocketServerImpl(int port) {
        super(new InetSocketAddress(port));
    }

    public WebSocketServerImpl(int port, List<Draft> drafts) {
        super(new InetSocketAddress(port), drafts);
    }

    public CallbackContext getCallbackContext() {
        return this.callbackContext;
    }

    public void setCallbackContext(CallbackContext callbackContext) {
        this.callbackContext = callbackContext;
    }

    public void setOrigins(List<String> origins) {
        this.origins = origins;
    }

    @Override
    public ServerHandshakeBuilder onWebsocketHandshakeReceivedAsServer(WebSocket conn, Draft draft,
            ClientHandshake request) throws InvalidDataException {

        ServerHandshakeBuilder serverHandshakeBuilder = super.onWebsocketHandshakeReceivedAsServer(conn, draft,
                request);

        if (origins != null) {
            String origin = request.getFieldValue("Origin");
            if (origins.indexOf(origin) == -1) {
                Log.w(WebSocketServerPlugin.TAG, "handshake: origin denied: " + origin);
                throw new InvalidDataException(CloseFrame.REFUSE);
            }
        }

        return serverHandshakeBuilder;
    }

    @Override
    public void onOpen(WebSocket webSocket, ClientHandshake clientHandshake) {
        Log.v(WebSocketServerPlugin.TAG, "onopen");

        String uuid;
        do {
            // prevent collision
            uuid = UUID.randomUUID().toString();
        } while (UUIDSockets.putIfAbsent(uuid, webSocket) != null);
        socketsUUID.put(webSocket, uuid);

        try {
            JSONObject httpFields = new JSONObject();
            Iterator<String> iterator = clientHandshake.iterateHttpFields();
            while (iterator.hasNext()) {
                String httpField = iterator.next();
                httpFields.put(httpField, clientHandshake.getFieldValue(httpField));
            }

            JSONObject conn = new JSONObject();
            conn.put("uuid", uuid);
            InetAddress addr = webSocket.getRemoteSocketAddress().getAddress();
            conn.put("remoteAddr", addr == null ? null : addr.getHostAddress());
            conn.put("httpFields", httpFields);
            conn.put("resource", clientHandshake.getResourceDescriptor());

            JSONObject status = new JSONObject();
            status.put("action", "onOpen");
            status.put("conn", conn);

            // httpFields may carry cookies or auth headers, so only the uuid is logged
            Log.d(WebSocketServerPlugin.TAG, "onopen: " + uuid);
            PluginResult result = new PluginResult(PluginResult.Status.OK, status);
            result.setKeepCallback(true);
            callbackContext.sendPluginResult(result);

        } catch (JSONException e) {
            Log.e(WebSocketServerPlugin.TAG, e.getMessage(), e);
            callbackContext.error("Error: " + e.getMessage());
        }
    }

    @Override
    public void onMessage(WebSocket webSocket, String msg) {
        Log.v(WebSocketServerPlugin.TAG, "onmessage");

        String uuid = socketsUUID.get(webSocket);

        if (uuid != null) {
            try {
                JSONObject status = new JSONObject();
                status.put("action", "onMessage");
                status.put("uuid", uuid);
                status.put("msg", msg);

                Log.d(WebSocketServerPlugin.TAG, "onmessage: " + uuid + " (" + msg.length() + " chars)");
                PluginResult result = new PluginResult(PluginResult.Status.OK, status);
                result.setKeepCallback(true);
                callbackContext.sendPluginResult(result);

            } catch (JSONException e) {
                Log.e(WebSocketServerPlugin.TAG, e.getMessage(), e);
                callbackContext.error("Error: " + e.getMessage());
            }
        } else {
            Log.d(WebSocketServerPlugin.TAG, "onmessage: unknown websocket");
        }

    }

    @Override
    public void onMessage(WebSocket webSocket, ByteBuffer binary){
        Log.v(WebSocketServerPlugin.TAG, "onmessage (binary)");

        String uuid = socketsUUID.get(webSocket);

        if (uuid != null) {
            try {
                // convert ByteBuffer to byte[]
                byte[] bin = new byte[binary.remaining()];
                binary.get(bin);

                JSONObject status = new JSONObject();
                status.put("action", "onMessage");
                status.put("uuid", uuid);
                // NO_WRAP: DEFAULT inserts a newline every 76 chars
                status.put("msg", Base64.encodeToString(bin, Base64.NO_WRAP));
                status.put("is_binary", true);

                Log.d(WebSocketServerPlugin.TAG, "onmessage (binary): " + uuid + " (" + bin.length + " bytes)");
                PluginResult result = new PluginResult(PluginResult.Status.OK, status);
                result.setKeepCallback(true);
                callbackContext.sendPluginResult(result);

            } catch (JSONException e) {
                Log.e(WebSocketServerPlugin.TAG, e.getMessage(), e);
                callbackContext.error("Error: " + e.getMessage());
            }
        } else {
            Log.d(WebSocketServerPlugin.TAG, "onmessage (binary): unknown websocket");
        }
    }

    @Override
    public void onClose(WebSocket webSocket, int code, String reason, boolean remote) {
        Log.v(WebSocketServerPlugin.TAG, "onclose");

        if (webSocket != null) {

            String uuid = socketsUUID.get(webSocket);

            if (uuid != null) {
                try {
                    JSONObject status = new JSONObject();
                    status.put("action", "onClose");
                    status.put("uuid", uuid);
                    status.put("code", code);
                    status.put("reason", reason);

                    boolean wasClean = true;
                    for (int notCleanCode : notCleanCodes) {
                        if (code == notCleanCode) {
                            wasClean = false;
                            break;
                        }
                    }
                    status.put("wasClean", wasClean);

                    Log.d(WebSocketServerPlugin.TAG, "onclose result: " + status.toString());
                    PluginResult result = new PluginResult(PluginResult.Status.OK, status);
                    result.setKeepCallback(true);
                    callbackContext.sendPluginResult(result);

                } catch (JSONException e) {
                    Log.e(WebSocketServerPlugin.TAG, e.getMessage(), e);
                    callbackContext.error("Error: " + e.getMessage());
                } finally {
                    socketsUUID.remove(webSocket);
                    UUIDSockets.remove(uuid);
                }
            } else {
                Log.d(WebSocketServerPlugin.TAG, "onclose: unknown websocket");
            }

        }

    }

    @Override
    public void onError(WebSocket webSocket, Exception exception) {
        Log.v(WebSocketServerPlugin.TAG, "onerror");

        if (exception != null) {
            Log.e(WebSocketServerPlugin.TAG, "onerror: " + exception.getMessage());
            exception.printStackTrace();
        }

        if (webSocket == null) {
            // server error
            try {
                try {
                    // normally already stopped. just making sure!
                    this.stop();
                } catch (InterruptedException | RuntimeException e) {
                    // fail silently
                    Log.e(WebSocketServerPlugin.TAG, e.getMessage(), e);
                }

                JSONObject status = new JSONObject();
                status.put("action", "onFailure");
                status.put("addr", this.getHostAddress());
                status.put("port", this.getPort());
                if (exception != null) {
                    status.put("reason", exception.getMessage());
                }

                Log.d(WebSocketServerPlugin.TAG, "onerror result: " + status.toString());
                PluginResult result = new PluginResult(PluginResult.Status.OK, status);
                result.setKeepCallback(false);
                callbackContext.sendPluginResult(result);

            } catch (JSONException e) {
                Log.e(WebSocketServerPlugin.TAG, e.getMessage(), e);
                callbackContext.error("Error: " + e.getMessage());

            } finally {
                // Keep the maps and callback context: other worker threads may still be
                // delivering onClose/onMessage. Late results on the finished callback are
                // dropped by Cordova.
                failed = true;
            }

        } else {
            // fatal error
            if (webSocket.isOpen()) {
                webSocket.close(CloseFrame.UNEXPECTED_CONDITION);
            }
        }

    }

    @Override
    public void onStart() {
        Log.v(WebSocketServerPlugin.TAG, "onstart");

        try {
            JSONObject status = new JSONObject();
            status.put("addr", this.getHostAddress());
            status.put("port", this.getPort());

            Log.d(WebSocketServerPlugin.TAG, "start result: " + status.toString());
            PluginResult result = new PluginResult(PluginResult.Status.OK, status);
            result.setKeepCallback(true);
            callbackContext.sendPluginResult(result);

        } catch (JSONException e) {
            Log.e(WebSocketServerPlugin.TAG, e.getMessage(), e);
        }
    }

    public void send(String uuid, String msg, boolean is_binary) {
        Log.v(WebSocketServerPlugin.TAG, "send");

        WebSocket webSocket = this.failed ? null : UUIDSockets.get(uuid);

        if (webSocket != null) {
            if (webSocket.isOpen()) {
                if (!is_binary) {
                    // send text frame (websocket opcode 1)
                    webSocket.send(msg);
                } else {
                    // send binary frame (websocket opcode 2)
                    try {
                        webSocket.send(Base64.decode(msg, Base64.DEFAULT));
                    } catch(IllegalArgumentException e) {
                        Log.d(WebSocketServerPlugin.TAG, "send: wrong binary format");
                    }
                }
            } else {
                Log.d(WebSocketServerPlugin.TAG, "send: websocket not open");
            }
        } else {
            Log.d(WebSocketServerPlugin.TAG, "send: unknown websocket");
        }

    }

    public void close(String uuid, int code, String reason) {
        Log.v(WebSocketServerPlugin.TAG, "close");

        WebSocket webSocket = this.failed ? null : UUIDSockets.get(uuid);

        if (webSocket != null) {
            if (code == -1) {
                webSocket.close(CloseFrame.NORMAL);
            } else {
                webSocket.close(code, reason);
            }
        } else {
            Log.d(WebSocketServerPlugin.TAG, "close: unknown websocket");
        }

    }

    public String getHostAddress() {
        InetSocketAddress socketAddr = this.getAddress();
        if (socketAddr == null) {
            return null;
        }
        InetAddress addr = socketAddr.getAddress();
        if (addr == null) {
            return null;
        }
        return addr.getHostAddress();
    }

}
