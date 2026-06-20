<div align="center">
  <img src="./docs/public/Logo.png" class="center">
</div>

[![GitHub License](https://img.shields.io/github/license/1Axen/blink?style=flat-square&color=%23a350af)](LICENSE)
[![GitHub Release](https://img.shields.io/github/v/release/1Axen/blink?style=flat-square&color=%23a350af)](https://github.com/1Axen/blink/releases/latest)

An IDL compiler written in Luau for ROBLOX buffer networking

# Performance
Blink aims to generate the most performant and bandwidth-efficient code for your specific experience, but what does this mean?  

It means lower bandwidth usage directly resulting in **lower ping\*** experienced by players and secondly, it means **lower CPU usage** compared to more generalized networking solutions.

*\* In comparison to standard ROBLOX networking, this may not always be the case but should never result in increased ping times.*

Benchmarks are available here [here](./benchmark/Benchmarks.md).
This fork is a v2-only hardened networking engine. Production rollout helpers, capture/replay, strict build checks, schema migrations, load simulation, and replication adapters are documented in [Production Upgrades](./docs/pages/getting-started/5-production-upgrades.mdx). The full fork integration guide is in [Blink V2 Fork Guide](./docs/pages/getting-started/6-blink-v2-fork.mdx).

# Security
Blink does not claim remote spying can be fully prevented. A client can always observe traffic that reaches that client. This fork makes spying and replaying traffic less useful by keeping authority on the server, never putting secrets in remotes, enforcing v2 schema/hash compatibility, rejecting stale or duplicate packets, validating schema policies before handlers run, scoring abuse, and surfacing structured security violations.

# Get Started
Head over to the [installation](https://1axen.github.io/blink/getting-started/1-installation) page to get started with Blink.

# Credits
Credits to [Zap](https://zap.redblox.dev/) for the range and array syntax  
Credits to [ArvidSilverlock](https://github.com/ArvidSilverlock) for the float16 implementation  
Studio plugin auto completion icons are sourced from [Microsoft](https://github.com/microsoft/vscode-icons) and are under the [CC BY 4.0](https://github.com/microsoft/vscode-icons/blob/main/LICENSE) license.  
<a href="https://www.flaticon.com/free-icons/speed" title="speed icons">Speed icons created by alkhalifi design - Flaticon</a>
