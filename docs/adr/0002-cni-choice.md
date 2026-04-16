# ADR-0002 — CNI choice: Azure Overlay + Cilium dataplane, no istio-cni

- **Status:** Accepted
- **Date:** initial deployment

## Context

AKS offers several CNI options: kubenet (deprecated), Azure CNI (VNet IP
per pod), Azure CNI Overlay (IP-per-pod from overlay address space), and
Azure CNI Powered by Cilium (eBPF dataplane on top of Azure CNI). Istio
itself ships a CNI plugin (`istio-cni`) that replaces the sidecar's
`NET_ADMIN` init-container by programming iptables at the node level.

The VNet address space per region is `10.x.0.0/16` with a dedicated AKS
subnet `/20`. Giving each pod a VNet IP from the AKS subnet would exhaust
IPs quickly at scale; using the Azure CNI Overlay keeps pod IPs in a
private overlay space independent of the VNet.

## Decision

- Use **Azure CNI Overlay with the Cilium dataplane**
  (`--network-plugin azure --network-plugin-mode overlay --network-dataplane cilium`).
- Do **not** install `istio-cni`. Cilium handles all pod networking and
  Istio's default sidecar init-container is sufficient; adding istio-cni
  on top of Cilium doubles the iptables/eBPF programming and has no upside.

## Consequences

- Pod IPs come from an overlay CIDR; VNet IP consumption is driven only by
  node IPs and ILB IPs. Cross-cluster traffic from pods is always SNATed
  to the node IP.
- NetworkPolicy is enforced by Cilium (fast eBPF path). `podSelector`,
  `namespaceSelector`, `ipBlock`, and port-based rules all work; CIDR
  selectors match the overlay, not VNet addresses.
- Debugging tools that rely on VNet pod IPs (e.g. NSG flow logs per pod)
  will not see pod-granular flows — use Hubble / Cilium flow logs instead.
- Istio sidecars still require the `istio-init` container with `NET_ADMIN`
  unless istio-cni is enabled. Pod security policies in `my-app` allow
  this via the istio-injection label; keep that in mind when applying
  PSA-restricted to other namespaces.

## Alternatives considered

- **istio-cni on top of Cilium**: rejected — redundant iptables
  programming, harder to debug, no measurable benefit on modern kernels.
- **Pure Azure CNI (no overlay)**: rejected — VNet IP exhaustion risk at
  scale; forces careful subnet sizing.
- **Kubenet**: rejected — deprecated.
