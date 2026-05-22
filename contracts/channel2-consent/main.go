package main

import (
	"log"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

func main() {
	cc, err := contractapi.NewChaincode(&ConsentAuditContract{})
	if err != nil {
		log.Panicf("channel2-consent: failed to create chaincode: %v", err)
	}
	if err := cc.Start(); err != nil {
		log.Panicf("channel2-consent: failed to start chaincode: %v", err)
	}
}
