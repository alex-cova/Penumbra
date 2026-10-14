package app;

import java.io.IOException;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.ArrayList;
import java.util.List;

/**
 * What the profiler's fixtures record: a CPU spin, sleeps, a socket read, monitor contention, an
 * Object.wait, allocation and two collections. Run by regenerate.sh under each JDK.
 */
public class Mixed {
    static final Object LOCK = new Object();
    static final Object WAITER = new Object();
    static volatile long sink;

    public static void main(String[] args) throws Exception {
        ServerSocket server = new ServerSocket(0, 1, InetAddress.getLoopbackAddress());
        Thread serverThread = new Thread(() -> serve(server), "socket-server");
        serverThread.start();
        try (Socket client = new Socket(InetAddress.getLoopbackAddress(), server.getLocalPort())) {
            client.getInputStream().read();
        }
        serverThread.join();
        server.close();

        sleep(400);
        contend();
        synchronized (WAITER) {
            WAITER.wait(150);
        }
        allocate();
        spin(600);
        System.gc();
        sleep(1100);
        System.gc();
    }

    static void serve(ServerSocket server) {
        try (Socket socket = server.accept()) {
            sleep(300);
            socket.getOutputStream().write(1);
            socket.getOutputStream().flush();
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
    }

    static void contend() throws InterruptedException {
        Thread holder = new Thread(() -> {
            synchronized (LOCK) {
                sleep(300);
            }
        }, "lock-holder");
        holder.start();
        sleep(50);
        Thread waiter = new Thread(() -> {
            synchronized (LOCK) {
                sink++;
            }
        }, "lock-waiter");
        waiter.start();
        holder.join();
        waiter.join();
    }

    static void allocate() {
        List<byte[]> kept = new ArrayList<>();
        for (int i = 0; i < 4_000; i++) {
            kept.add(new byte[16 * 1024]);
            if (kept.size() > 200) kept.clear();
        }
        sink += kept.size();
    }

    static void spin(long milliseconds) {
        long end = System.nanoTime() + milliseconds * 1_000_000;
        long x = 1;
        while (System.nanoTime() < end) {
            for (int i = 0; i < 10_000; i++) x = x * 31 + i;
        }
        sink += x;
    }

    static void sleep(long milliseconds) {
        try {
            Thread.sleep(milliseconds);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
