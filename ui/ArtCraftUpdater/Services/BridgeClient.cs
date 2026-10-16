using System;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ArtCraftUpdater.Wpf
{
    /// <summary>
    /// Runs the PowerShell JSON bridge out of process and exchanges one
    /// protocol-v1 request/response pair. Never executes anything except the
    /// explicit bridge script. Kills the child on timeout or cancellation.
    /// </summary>
    public sealed class BridgeClient : IDisposable
    {
        private readonly string _bridgeScript;
        private readonly int _timeoutMs;

        public BridgeClient(string bridgeScript, int timeoutMs = 120000)
        {
            _bridgeScript = bridgeScript ?? throw new ArgumentNullException(nameof(bridgeScript));
            _timeoutMs = timeoutMs;
        }

        public async Task<JsonDocument> InvokeAsync(string operation, CancellationToken cancellationToken)
        {
            return await InvokeAsync(operation, "{}", cancellationToken).ConfigureAwait(false);
        }

        public async Task<JsonDocument> InvokeAsync(string operation, string paramsJson, CancellationToken cancellationToken)
        {
            System.Tuple<string, string> pair = await InvokeCoreAsync(operation, paramsJson ?? "{}", cancellationToken).ConfigureAwait(false);
            return ParseResponse(operation, pair.Item1, pair.Item2);
        }

        public async Task<string> InvokeOperationAsync(string operation, string paramsJson, CancellationToken cancellationToken)
        {
            System.Tuple<string, string> pair = await InvokeCoreAsync(operation, paramsJson, cancellationToken).ConfigureAwait(false);
            return "{\"id\":\"" + pair.Item1 + "\",\"line\":" + JsonEncode(pair.Item2) + "}";
        }

        private static string JsonEncode(string value)
        {
            if (value == null) { return "null"; }
            return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"")
                .Replace("\r", "\\r").Replace("\n", "\\n").Replace("\t", "\\t") + "\"";
        }

        private static JsonDocument ParseResponse(string operation, string id, string firstLine)
        {
            var document = JsonDocument.Parse(firstLine);
            JsonElement root = document.RootElement;
            if (!root.TryGetProperty("id", out JsonElement idElement) ||
                idElement.GetString() != id)
            {
                document.Dispose();
                throw new InvalidOperationException("Bridge response id mismatch.");
            }
            return document;
        }

        private async Task<System.Tuple<string, string>> InvokeCoreAsync(string operation, string paramsJson, CancellationToken cancellationToken)
        {
            string id = Guid.NewGuid().ToString("N");
            string request = "{\"protocol\":1,\"id\":\"" + id + "\",\"op\":\"" + operation + "\",\"params\":" + paramsJson + "}";
            var psi = new ProcessStartInfo
            {
                FileName = System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    "WindowsPowerShell\\v1.0\\powershell.exe"),
                Arguments = "-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File \"" + _bridgeScript + "\"",
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                // UTF8Encoding(false): no byte-order mark. Encoding.UTF8 emits
                // a BOM preamble that Windows PowerShell 5.1 ConvertFrom-Json
                // rejects, which used to surface as "malformed-request" and
                // then as a bridge id mismatch on the client.
                StandardInputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
                StandardOutputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false)
            };
            using (var process = new Process { StartInfo = psi })
            {
                process.Start();
                try
                {
                    await process.StandardInput.WriteLineAsync(request).ConfigureAwait(false);
                    process.StandardInput.Close();
                    var outputTask = process.StandardOutput.ReadToEndAsync();
                    var completed = await Task.WhenAny(outputTask,
                        Task.Delay(_timeoutMs, cancellationToken)).ConfigureAwait(false);
                    if (completed != outputTask)
                    {
                        throw new TimeoutException("Bridge request '" + operation + "' timed out.");
                    }
                    string output = ((Task<string>)completed).Result;
                    if (string.IsNullOrWhiteSpace(output))
                    {
                        throw new InvalidOperationException("Bridge produced no protocol output.");
                    }
                    string firstLine = output.Split(new[] { '\r', '\n' },
                        StringSplitOptions.RemoveEmptyEntries)[0];
                    return System.Tuple.Create(id, firstLine);
                }
                finally
                {
                    try
                    {
                        if (!process.HasExited)
                        {
                            process.Kill();
                        }
                    }
                    catch (InvalidOperationException) { }
                }
            }
        }

        public void Dispose()
        {
        }
    }
}
