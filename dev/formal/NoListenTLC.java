import java.io.IOException;
import java.io.InterruptedIOException;
import java.net.ServerSocket;
import java.net.Socket;
import java.rmi.server.RMISocketFactory;

/**
 * TLC (tlc2.TLC, tla2tools.jar v1.7.4) whose RMI exports open no socket, so the model checker runs where no socket
 * may be bound: a landing's `check` sandbox (dev/climb/door.py profile(kind="check"): no network-bind, no
 * network-inbound, no network-outbound). TLC's fingerprint set, tlc2.tool.fp.FPSet, extends
 * java.rmi.server.UnicastRemoteObject (read with javap: every FPSet implementation inherits it, and FPSetFactory's
 * `.impl` property only chooses among them), and that constructor exports the object on an anonymous port through the
 * default RMISocketFactory: inside the sandbox, "java.rmi.server.ExportException: Port already in use: 0 ...
 * BindException: Operation not permitted" (2026-11-14, a landing that touched dev/formal). Its precedent is the JDK's
 * own hook for this: java.rmi.server.RMISocketFactory.setSocketFactory, "the global socket factory from which RMI
 * gets sockets". The factory set here makes a server socket that is never bound and never listens (its accept waits
 * until the JVM exits; TLC calls no remote object) and refuses every client socket, so no TLC run opens a connection
 * either way. dev/formal/run_tlc.sh compiles it once a run and runs every instance through it.
 */
public final class NoListenTLC {
    /** A server socket that is never bound: RMI's export reads its port and starts an accept loop on it. */
    static final class Unbound extends ServerSocket {
        Unbound() throws IOException { super(); }
        @Override public Socket accept() throws IOException {
            synchronized (this) {
                while (true) {
                    try { wait(); } catch (InterruptedException e) { throw new InterruptedIOException("NoListenTLC"); }
                }
            }
        }
        @Override public int getLocalPort() { return 1; }
        @Override public void close() { }
    }

    public static void main(String[] args) throws Exception {
        RMISocketFactory.setSocketFactory(new RMISocketFactory() {
            @Override public ServerSocket createServerSocket(int port) throws IOException { return new Unbound(); }
            @Override public Socket createSocket(String host, int port) throws IOException {
                throw new IOException("NoListenTLC: TLC opens no connection (" + host + ":" + port + ")");
            }
        });
        tlc2.TLC.main(args);
    }
}
