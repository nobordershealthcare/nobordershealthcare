package main

import (
	"fmt"
	"os"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

func main() {
	cc, err := contractapi.NewChaincode(&MilitaryContract{})
	if err != nil {
		fmt.Fprintln(os.Stderr, "error creating channel4-military chaincode:", err)
		os.Exit(1)
	}
	if err := cc.Start(); err != nil {
		fmt.Fprintln(os.Stderr, "error starting channel4-military chaincode:", err)
		os.Exit(1)
	}
}
