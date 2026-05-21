package main

import (
	"log"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

func main() {
	cc, err := contractapi.NewChaincode(&AccessControlContract{})
	if err != nil {
		log.Panicf("failed to create chaincode: %v", err)
	}
	if err := cc.Start(); err != nil {
		log.Panicf("failed to start chaincode: %v", err)
	}
}
