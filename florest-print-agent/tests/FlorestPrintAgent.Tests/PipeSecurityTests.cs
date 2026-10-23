using System;
using System.IO.Pipes;
using System.Linq;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core;
using FlorestPrintAgent.Core.Agent;
using FlorestPrintAgent.Core.Ipc;
using Xunit;

namespace FlorestPrintAgent.Tests
{
    /// <summary>
    /// Testes que dependem do Windows (ACL do pipe e identidade do chamador). Em outros sistemas operacionais retornam sem
    /// verificar nada — o relatório da revisão informa em que sistema cada teste realmente executou.
    /// </summary>
    public class PipeSecurityTests
    {
        [SupportedOSPlatform("windows")]
        private static PipeAccessRule[] Rules(PipeSecurity security)
        {
            return security.GetAccessRules(true, false, typeof(SecurityIdentifier)).Cast<PipeAccessRule>().ToArray();
        }

        [SupportedOSPlatform("windows")]
        private static PipeAccessRule? RuleFor(PipeAccessRule[] rules, WellKnownSidType type, AccessControlType access)
        {
            SecurityIdentifier sid = new SecurityIdentifier(type, null);
            return rules.FirstOrDefault(r => r.AccessControlType == access && r.IdentityReference.Equals(sid));
        }

        [Fact]
        public void AclDeniesNetworkAndNeverGrantsEveryoneUsersOrAuthenticatedUsers()
        {
            if (!OperatingSystem.IsWindows()) return;

            PipeAccessRule[] rules = Rules(PipeSecurityFactory.Create());

            PipeAccessRule? denyNetwork = RuleFor(rules, WellKnownSidType.NetworkSid, AccessControlType.Deny);
            Assert.NotNull(denyNetwork);
            Assert.Equal(PipeAccessRights.FullControl, denyNetwork!.PipeAccessRights & PipeAccessRights.FullControl);

            Assert.Null(RuleFor(rules, WellKnownSidType.WorldSid, AccessControlType.Allow));
            Assert.Null(RuleFor(rules, WellKnownSidType.BuiltinUsersSid, AccessControlType.Allow));
            Assert.Null(RuleFor(rules, WellKnownSidType.AuthenticatedUserSid, AccessControlType.Allow));
            Assert.Null(RuleFor(rules, WellKnownSidType.AnonymousSid, AccessControlType.Allow));
            Assert.Null(RuleFor(rules, WellKnownSidType.BuiltinGuestsSid, AccessControlType.Allow));
        }

        [Fact]
        public void AclGivesFullControlOnlyToSystemAdministratorsAndTheProcessIdentity()
        {
            if (!OperatingSystem.IsWindows()) return;

            PipeAccessRule[] rules = Rules(PipeSecurityFactory.Create());
            SecurityIdentifier network = new SecurityIdentifier(WellKnownSidType.NetworkSid, null);
            SecurityIdentifier interactive = new SecurityIdentifier(WellKnownSidType.InteractiveSid, null);
            SecurityIdentifier system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
            SecurityIdentifier admins = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
            string self;
            using (WindowsIdentity me = WindowsIdentity.GetCurrent())
                self = me.User!.Value;

            foreach (PipeAccessRule rule in rules.Where(r => r.AccessControlType == AccessControlType.Allow))
            {
                string who = rule.IdentityReference.Value;
                bool full = (rule.PipeAccessRights & PipeAccessRights.FullControl) == PipeAccessRights.FullControl;
                if (full)
                    Assert.True(who == system.Value || who == admins.Value || who == self, "FullControl inesperado para " + who);
                else
                    Assert.Equal(interactive.Value, who);
                Assert.NotEqual(network.Value, who);
            }

            Assert.NotNull(RuleFor(rules, WellKnownSidType.LocalSystemSid, AccessControlType.Allow));
            Assert.NotNull(RuleFor(rules, WellKnownSidType.BuiltinAdministratorsSid, AccessControlType.Allow));
        }

        [Fact]
        public void InteractiveUsersCanOnlyReadAndWriteAndCannotCreateInstancesOrChangeTheAcl()
        {
            if (!OperatingSystem.IsWindows()) return;

            PipeAccessRule[] rules = Rules(PipeSecurityFactory.Create());
            PipeAccessRule? interactive = RuleFor(rules, WellKnownSidType.InteractiveSid, AccessControlType.Allow);

            Assert.NotNull(interactive);
            PipeAccessRights r = interactive!.PipeAccessRights;
            Assert.True((r & PipeAccessRights.ReadWrite) == PipeAccessRights.ReadWrite);
            Assert.True((r & PipeAccessRights.Synchronize) != 0);
            Assert.True((r & PipeAccessRights.CreateNewInstance) == 0, "usuário comum não pode criar instâncias do pipe");
            Assert.True((r & PipeAccessRights.ChangePermissions) == 0);
            Assert.True((r & PipeAccessRights.TakeOwnership) == 0);
            Assert.True((r & PipeAccessRights.Delete) == 0);
        }

        [Fact]
        public void DenyRulesComeBeforeAllowRules()
        {
            if (!OperatingSystem.IsWindows()) return;

            PipeSecurity security = PipeSecurityFactory.Create();
            RawSecurityDescriptor descriptor = new RawSecurityDescriptor(security.GetSecurityDescriptorBinaryForm(), 0);
            Assert.NotNull(descriptor.DiscretionaryAcl);
            bool seenAllow = false;
            foreach (GenericAce ace in descriptor.DiscretionaryAcl)
            {
                if (ace.AceType == AceType.AccessAllowed) seenAllow = true;
                if (ace.AceType == AceType.AccessDenied)
                    Assert.False(seenAllow, "ACE de negação depois de uma ACE de permissão");
            }
        }

        [Fact]
        public async Task ServerSeesTheRealWindowsIdentityAndSessionOfTheConnectedClient()
        {
            if (!OperatingSystem.IsWindows()) return;

            // Mesmas condições do IpcServer real: ACL de PipeSecurityFactory, PipeOptions.Asynchronous, buffers de
            // AgentConstants.IpcPipeBufferBytes (NUNCA 0 — com buffer zero a escrita do cliente só termina quando o servidor
            // lê, e este teste escrevia e aguardava ANTES de o servidor ler: travava até o cancelamento) e o mesmo
            // enquadramento (IpcFraming) que o Tray e o Service usam.
            string name = "FlorestPrintAgent.Test." + Guid.NewGuid().ToString("N");
            using (CancellationTokenSource cts = new CancellationTokenSource(TimeSpan.FromSeconds(30))) // só evita travar a suíte
            using (NamedPipeServerStream server = NamedPipeServerStreamAcl.Create(
                name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous,
                AgentConstants.IpcPipeBufferBytes, AgentConstants.IpcPipeBufferBytes, PipeSecurityFactory.Create()))
            using (NamedPipeClientStream client = new NamedPipeClientStream(
                ".", name, PipeDirection.InOut, PipeOptions.Asynchronous, TokenImpersonationLevel.Identification))
            {
                Task accept = server.WaitForConnectionAsync(cts.Token);
                await client.ConnectAsync(5000, cts.Token);
                await accept;

                // cliente escreve e servidor lê AO MESMO TEMPO (como no uso real)
                byte[] message = Encoding.UTF8.GetBytes("{\"v\":1,\"cmd\":\"status\"}");
                Task write = IpcFraming.WriteFrameAsync(client, message, AgentConstants.MaxIpcRequestBytes, cts.Token);
                byte[] received = await IpcFraming.ReadFrameAsync(server, AgentConstants.MaxIpcRequestBytes, cts.Token);
                await write;
                Assert.Equal(message, received);

                // o Windows só deixa o servidor representar o cliente depois de ter LIDO a primeira mensagem dele
                CallerIdentity caller = PipeCallerIdentity.Identify(server);

                string expectedSid;
                using (WindowsIdentity me = WindowsIdentity.GetCurrent())
                    expectedSid = me.User!.Value;

                Assert.Equal(expectedSid, caller.Sid);
                Assert.True(caller.SessionId >= 0);
                Assert.Equal(expectedSid + "#" + caller.SessionId, caller.Key);
            }
        }
    }
}
