using System.Text.Json;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Rfcomm;
using Windows.Networking.Sockets;
using Windows.Storage.Streams;

internal static class Program
{
    private static readonly object StdoutLock = new();

    private sealed record BridgeMessage(string type, bool? ok = null, string? message = null, string? data = null);

    public static async Task<int> Main(string[] args)
    {
        string? mac = null;
        string? uuid = null;

        for (int i = 0; i < args.Length - 1; i++)
        {
            if (args[i] == "--mac")
            {
                mac = args[i + 1];
            }
            else if (args[i] == "--uuid")
            {
                uuid = args[i + 1];
            }
        }

        if (string.IsNullOrWhiteSpace(mac) || string.IsNullOrWhiteSpace(uuid))
        {
            WriteMessage(new BridgeMessage("status", false, "--mac ve --uuid gerekli."));
            return 1;
        }

        try
        {
            ulong address = ParseMacAddress(mac);
            BluetoothDevice? device = await BluetoothDevice.FromBluetoothAddressAsync(address);
            if (device is null)
            {
                WriteMessage(new BridgeMessage("status", false, "BluetoothDevice bulunamadi."));
                return 2;
            }

            Guid serviceGuid = Guid.Parse(uuid);
            RfcommDeviceServicesResult servicesResult = await device.GetRfcommServicesForIdAsync(
                RfcommServiceId.FromUuid(serviceGuid),
                BluetoothCacheMode.Uncached);

            if (servicesResult.Services.Count == 0)
            {
                WriteMessage(new BridgeMessage("status", false, $"RFCOMM servis bulunamadi: {serviceGuid}"));
                return 3;
            }

            RfcommDeviceService service = servicesResult.Services[0];
            using StreamSocket socket = new();
            await socket.ConnectAsync(service.ConnectionHostName, service.ConnectionServiceName);

            using DataWriter writer = new(socket.OutputStream)
            {
                UnicodeEncoding = Windows.Storage.Streams.UnicodeEncoding.Utf8,
            };
            using CancellationTokenSource cts = new();

            Task readTask = ReadLoopAsync(socket.InputStream, cts.Token);

            WriteMessage(new BridgeMessage("status", true, "RFCOMM baglandi"));

            while (true)
            {
                string? line = await Console.In.ReadLineAsync();
                if (line is null)
                {
                    break;
                }

                using JsonDocument doc = JsonDocument.Parse(line);
                string type = doc.RootElement.GetProperty("type").GetString() ?? string.Empty;

                if (type == "disconnect")
                {
                    break;
                }

                if (type == "send")
                {
                    string base64 = doc.RootElement.GetProperty("data").GetString() ?? string.Empty;
                    if (!string.IsNullOrEmpty(base64))
                    {
                        byte[] payload = Convert.FromBase64String(base64);
                        writer.WriteBytes(payload);
                        await writer.StoreAsync();
                        await writer.FlushAsync();
                    }
                }
            }

            cts.Cancel();
            try
            {
                await readTask;
            }
            catch
            {
                // Ignore read loop cancellation errors.
            }

            return 0;
        }
        catch (Exception ex)
        {
            WriteMessage(new BridgeMessage("status", false, ex.Message));
            return 10;
        }
    }

    private static async Task ReadLoopAsync(IInputStream input, CancellationToken ct)
    {
        using DataReader reader = new(input)
        {
            InputStreamOptions = InputStreamOptions.Partial,
            UnicodeEncoding = Windows.Storage.Streams.UnicodeEncoding.Utf8,
        };

        while (!ct.IsCancellationRequested)
        {
            uint loaded = await reader.LoadAsync(2048).AsTask(ct);
            if (loaded == 0)
            {
                await Task.Delay(40, ct);
                continue;
            }

            byte[] data = new byte[loaded];
            reader.ReadBytes(data);

            WriteMessage(new BridgeMessage(
                "data",
                data: Convert.ToBase64String(data)));
        }
    }

    private static void WriteMessage(BridgeMessage message)
    {
        string json = JsonSerializer.Serialize(message);
        lock (StdoutLock)
        {
            Console.WriteLine(json);
            Console.Out.Flush();
        }
    }

    private static ulong ParseMacAddress(string mac)
    {
        string normalized = mac.Replace(":", string.Empty).Replace("-", string.Empty);
        return ulong.Parse(normalized, System.Globalization.NumberStyles.HexNumber);
    }
}
