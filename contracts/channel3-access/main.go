package main

import (
	"log"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

func main() {
	cc, err := contractapi.NewChaincode(&AccessAuditContract{})
	if err != nil {
		log.Panicf("channel3-access: failed to create chaincode: %v", err)
	}
	if err := cc.Start(); err != nil {
		log.Panicf("channel3-access: failed to start chaincode: %v", err)
	}
}
