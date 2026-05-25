package polygon

// NBHCTokenABI is the minimal ERC-20 ABI subset used by the token bridge.
// We only need Transfer events (for holder discovery) and
// balanceOf / totalSupply (for pro-rata distribution calculation).
const NBHCTokenABI = `[
  {
    "anonymous": false,
    "inputs": [
      {"indexed": true,  "internalType": "address", "name": "from",  "type": "address"},
      {"indexed": true,  "internalType": "address", "name": "to",    "type": "address"},
      {"internalType": "uint256", "name": "value", "type": "uint256"}
    ],
    "name": "Transfer",
    "type": "event"
  },
  {
    "inputs": [{"internalType": "address", "name": "account", "type": "address"}],
    "name": "balanceOf",
    "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [],
    "name": "totalSupply",
    "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
    "stateMutability": "view",
    "type": "function"
  }
]`
