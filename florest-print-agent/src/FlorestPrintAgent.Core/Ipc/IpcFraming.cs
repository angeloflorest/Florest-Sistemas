using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace FlorestPrintAgent.Core.Ipc
{
    public sealed class IpcProtocolException : Exception
    {
        public IpcProtocolException(string message)
            : base(message)
        {
        }
    }

    /// <summary>
    /// Enquadramento das mensagens: 4 bytes (inteiro little-endian com o tamanho) + JSON UTF-8.
    /// O tamanho é validado ANTES de alocar memória (limite explícito), então um cliente local não consegue
    /// forçar o serviço a alocar quantidades enormes.
    /// </summary>
    public static class IpcFraming
    {
        public static async Task WriteFrameAsync(Stream stream, byte[] payload, int maxBytes, CancellationToken ct)
        {
            if (payload.Length == 0 || payload.Length > maxBytes) throw new IpcProtocolException("Mensagem fora do limite de tamanho.");
            byte[] header = new byte[4];
            header[0] = (byte)(payload.Length & 0xFF);
            header[1] = (byte)((payload.Length >> 8) & 0xFF);
            header[2] = (byte)((payload.Length >> 16) & 0xFF);
            header[3] = (byte)((payload.Length >> 24) & 0xFF);
            await stream.WriteAsync(header, 0, 4, ct).ConfigureAwait(false);
            await stream.WriteAsync(payload, 0, payload.Length, ct).ConfigureAwait(false);
            await stream.FlushAsync(ct).ConfigureAwait(false);
        }

        public static async Task<byte[]> ReadFrameAsync(Stream stream, int maxBytes, CancellationToken ct)
        {
            byte[] header = new byte[4];
            if (!await ReadExactAsync(stream, header, 4, ct).ConfigureAwait(false))
                throw new IpcProtocolException("Conexão encerrada antes da mensagem.");

            int length = header[0] | (header[1] << 8) | (header[2] << 16) | (header[3] << 24);
            if (length <= 0 || length > maxBytes) throw new IpcProtocolException("Tamanho de mensagem inválido.");

            byte[] payload = new byte[length];
            if (!await ReadExactAsync(stream, payload, length, ct).ConfigureAwait(false))
                throw new IpcProtocolException("Mensagem incompleta.");
            return payload;
        }

        private static async Task<bool> ReadExactAsync(Stream stream, byte[] buffer, int count, CancellationToken ct)
        {
            int offset = 0;
            while (offset < count)
            {
                int read = await stream.ReadAsync(buffer, offset, count - offset, ct).ConfigureAwait(false);
                if (read == 0) return false;
                offset += read;
            }
            return true;
        }
    }

    public static class IpcSerializer
    {
        public static byte[] Serialize<T>(T value)
        {
            return JsonSerializer.SerializeToUtf8Bytes(value, AgentJson.Options);
        }

        public static T Deserialize<T>(byte[] payload) where T : class
        {
            try
            {
                T? value = JsonSerializer.Deserialize<T>(payload, AgentJson.Options);
                if (value == null) throw new IpcProtocolException("Mensagem vazia.");
                return value;
            }
            catch (JsonException)
            {
                throw new IpcProtocolException("Mensagem malformada.");
            }
        }
    }
}
