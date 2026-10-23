using System;
using System.IO;

namespace FlorestPrintAgent.Core.Storage
{
    /// <summary>
    /// Gravação atômica: escreve em arquivo temporário (mesma pasta), força o flush em disco e só então
    /// substitui o arquivo final. Uma queda de energia deixa o arquivo antigo OU o novo, nunca um arquivo cortado.
    /// </summary>
    public static class AtomicFile
    {
        public static void WriteAllBytes(string path, byte[] bytes)
        {
            string? dir = Path.GetDirectoryName(path);
            if (string.IsNullOrEmpty(dir)) throw new ArgumentException("Caminho inválido.", nameof(path));
            Directory.CreateDirectory(dir);

            string tmp = Path.Combine(dir, Path.GetFileName(path) + "." + Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                using (FileStream fs = new FileStream(tmp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
                {
                    fs.Write(bytes, 0, bytes.Length);
                    fs.Flush(true);
                }

                if (File.Exists(path))
                {
                    File.Replace(tmp, path, null);
                }
                else
                {
                    File.Move(tmp, path);
                }
            }
            catch
            {
                TryDelete(tmp);
                throw;
            }
        }

        public static void WriteAllText(string path, string text)
        {
            WriteAllBytes(path, new System.Text.UTF8Encoding(false).GetBytes(text));
        }

        /// <summary>Remove temporários órfãos (queda de energia no meio da gravação).</summary>
        public static void CleanupTemporaries(string directory)
        {
            try
            {
                if (!Directory.Exists(directory)) return;
                foreach (string f in Directory.GetFiles(directory, "*.tmp"))
                {
                    TryDelete(f);
                }
            }
            catch
            {
                // limpeza é "melhor esforço"
            }
        }

        public static void TryDelete(string path)
        {
            try
            {
                if (File.Exists(path)) File.Delete(path);
            }
            catch
            {
                // ignora
            }
        }
    }
}
