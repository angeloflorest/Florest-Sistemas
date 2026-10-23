using System;
using FlorestPrintAgent.Core.Security;
using FlorestPrintAgent.Tests.TestSupport;
using Xunit;

namespace FlorestPrintAgent.Tests
{
    public class TokenParserTests
    {
        private const string ValidSecret = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcde"; // 43 caracteres

        [Fact]
        public void SecretFixtureHas43Characters()
        {
            Assert.Equal(43, ValidSecret.Length);
        }

        [Fact]
        public void ParsesValidToken()
        {
            string raw = "fpa_123e4567-e89b-12d3-a456-426614174000." + ValidSecret;
            AgentToken? token;
            Assert.True(TokenParser.TryParse(raw, out token));
            Assert.NotNull(token);
            Assert.Equal("123e4567-e89b-12d3-a456-426614174000", token!.AgentId);
            Assert.Equal(raw, token.RevealForAuthorization());
        }

        [Fact]
        public void NormalizesAgentIdToLowerCase()
        {
            string raw = "fpa_123E4567-E89B-12D3-A456-426614174000." + ValidSecret;
            AgentToken? token;
            Assert.True(TokenParser.TryParse(raw, out token));
            Assert.Equal("123e4567-e89b-12d3-a456-426614174000", token!.AgentId);
            Assert.StartsWith("fpa_123e4567-e89b-12d3-a456-426614174000.", token.RevealForAuthorization(), StringComparison.Ordinal);
        }

        [Fact]
        public void ToStringNeverRevealsTheSecret()
        {
            AgentToken token = TestTokens.Make(7);
            string text = token.ToString();
            string full = token.RevealForAuthorization();
            string secret = full.Substring(full.IndexOf('.') + 1);
            Assert.DoesNotContain(secret, text, StringComparison.Ordinal);
            Assert.Contains("oculto", text, StringComparison.Ordinal);

            // interpolação de string (um log acidental) também não vaza
            string interpolated = $"token={token}";
            Assert.DoesNotContain(secret, interpolated, StringComparison.Ordinal);
        }

        [Theory]
        [InlineData(null)]
        [InlineData("")]
        [InlineData("fpa_")]
        [InlineData("xxx_123e4567-e89b-12d3-a456-426614174000.AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcde")]
        [InlineData("fpa_123e4567-e89b-12d3-a456-426614174000.curto")]
        [InlineData("fpa_123e4567-e89b-12d3-a456-426614174000.AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcdeX")]
        [InlineData("fpa_123e4567-e89b-12d3-a456-42661417400.AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcde")]
        [InlineData("fpa_123e4567-e89b-12d3-a456-426614174000.AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc+/")]
        [InlineData(" fpa_123e4567-e89b-12d3-a456-426614174000.AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcde")]
        public void RejectsMalformedTokens(string? raw)
        {
            AgentToken? token;
            Assert.False(TokenParser.TryParse(raw, out token));
            Assert.Null(token);
        }

        [Fact]
        public void RejectsVeryLongInput()
        {
            AgentToken? token;
            Assert.False(TokenParser.TryParse(new string('a', 5000), out token));
        }
    }

    public class PairingCodeTests
    {
        [Theory]
        [InlineData("ABCD-2345", "ABCD-2345")]
        [InlineData("abcd-2345", "ABCD-2345")]
        [InlineData("abcd2345", "ABCD-2345")]
        [InlineData("  AbCd 2345 ", "ABCD-2345")]
        [InlineData("ABCD - 2345", "ABCD-2345")]
        public void NormalizesValidCodes(string input, string expected)
        {
            string normalized;
            Assert.True(PairingCode.TryNormalize(input, out normalized));
            Assert.Equal(expected, normalized);
        }

        [Theory]
        [InlineData(null)]
        [InlineData("")]
        [InlineData("   ")]
        [InlineData("ABCD-234")]          // curto
        [InlineData("ABCD-23456")]        // longo
        [InlineData("ABCD-2O45")]         // contém O (fora do alfabeto)
        [InlineData("ABCD-2145")]         // contém 1 (fora do alfabeto)
        [InlineData("ABCD-2I45")]         // contém I
        [InlineData("ABCD-2045")]         // contém 0
        [InlineData("ABCD-23@5")]         // símbolo
        [InlineData("ABCD-2345-EXTRA-LONGO-DEMAIS-PARA-SER-CODIGO")]
        public void RejectsInvalidCodes(string? input)
        {
            string normalized;
            Assert.False(PairingCode.TryNormalize(input, out normalized));
            Assert.Equal(string.Empty, normalized);
        }
    }

    public class LogSanitizerTests
    {
        [Fact]
        public void MasksAgentToken()
        {
            AgentToken token = TestTokens.Make(3);
            string full = token.RevealForAuthorization();
            string scrubbed = LogSanitizer.Scrub("falha com " + full + " ao enviar");
            Assert.DoesNotContain(full, scrubbed, StringComparison.Ordinal);
            Assert.DoesNotContain(full.Substring(full.IndexOf('.') + 1), scrubbed, StringComparison.Ordinal);
            Assert.Contains("fpa_[REDACTED]", scrubbed, StringComparison.Ordinal);
        }

        [Fact]
        public void MasksBearerAndAuthorizationHeader()
        {
            string scrubbed = LogSanitizer.Scrub("Authorization: Bearer abc.def-ghi_123 e mais");
            Assert.DoesNotContain("abc.def-ghi_123", scrubbed, StringComparison.Ordinal);
        }

        [Fact]
        public void MasksPairingCode()
        {
            string scrubbed = LogSanitizer.Scrub("código ABCD-2345 digitado");
            Assert.DoesNotContain("ABCD-2345", scrubbed, StringComparison.Ordinal);
        }

        [Fact]
        public void MasksSha256Hex()
        {
            string hash = new string('a', 64);
            string scrubbed = LogSanitizer.Scrub("hash " + hash);
            Assert.DoesNotContain(hash, scrubbed, StringComparison.Ordinal);
        }

        [Fact]
        public void MasksABareTokenSecretWithoutThePrefix()
        {
            string full = TestTokens.Make(5).RevealForAuthorization();
            string secret = full.Substring(full.IndexOf('.') + 1);
            Assert.Equal(43, secret.Length);
            string scrubbed = LogSanitizer.Scrub("segredo solto " + secret + " no texto");
            Assert.DoesNotContain(secret, scrubbed, StringComparison.Ordinal);
        }

        [Fact]
        public void MasksJwt()
        {
            string jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdEFGH";
            string scrubbed = LogSanitizer.Scrub("jwt " + jwt);
            Assert.DoesNotContain(jwt, scrubbed, StringComparison.Ordinal);
        }

        [Fact]
        public void KeepsOrdinaryText()
        {
            Assert.Equal("Heartbeat OK.", LogSanitizer.Scrub("Heartbeat OK."));
            Assert.Equal(string.Empty, LogSanitizer.Scrub(null));
        }
    }

    public class IpValidatorTests
    {
        [Theory]
        [InlineData("192.168.0.50", "192.168.0.50")]
        [InlineData(" 10.0.0.9 ", "10.0.0.9")]
        [InlineData("172.16.5.200", "172.16.5.200")]
        public void AcceptsIpv4Literals(string input, string expected)
        {
            string normalized;
            Assert.True(IpValidator.TryNormalize(input, out normalized));
            Assert.Equal(expected, normalized);
        }

        [Theory]
        [InlineData(null)]
        [InlineData("")]
        [InlineData("impressora-cozinha")]
        [InlineData("impressora.local")]
        [InlineData("192.168.1")]       // IPAddress.TryParse aceitaria e inventaria 192.168.0.1
        [InlineData("1234")]            // idem: viraria 0.0.4.210
        [InlineData("256.1.1.1")]
        [InlineData("0.0.0.0")]
        [InlineData("127.0.0.1")]
        [InlineData("224.0.0.1")]
        [InlineData("255.255.255.255")]
        [InlineData("192.168.0.1:9100")]
        [InlineData("::")]
        [InlineData("::1")]
        [InlineData("fe80::1%12")]
        public void RejectsNonIpOrUnusableValues(string? input)
        {
            string normalized;
            Assert.False(IpValidator.TryNormalize(input, out normalized));
            Assert.Equal(string.Empty, normalized);
        }

        [Fact]
        public void AcceptsGlobalIpv6Literal()
        {
            string normalized;
            Assert.True(IpValidator.TryNormalize("2001:db8::10", out normalized));
            Assert.Equal("2001:db8::10", normalized);
        }
    }
}
