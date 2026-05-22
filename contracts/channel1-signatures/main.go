package main

import (
	"log"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

func main() {
	cc, err := contractapi.NewChaincode(&SignaturesContract{})
	if err != nil {
		log.Panicf("channel1-signatures: failed to create chaincode: %v", err)
	}
	if err := cc.Start(); err != nil {
		log.Panicf("channel1-signatures: failed to start chaincode: %v", err)
	}
}
