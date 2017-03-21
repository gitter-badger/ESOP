pragma solidity ^0.4.0;

import 'dapple/test.sol';
import 'dapple/reporter.sol';
import "./Test.DummyOptionConverter.sol";
import "./Test.Types.sol";

contract TestESOP is Test, Reporter, ESOPTypes
{
    EmpTester emp1;
    Tester emp2;
    ESOP esop;
    DummyOptionsConverter converter;

  function setUp() {
    emp1 = new EmpTester();
    emp2 = new Tester();
    esop = new ESOP();
    converter = new DummyOptionsConverter(address(esop));
  }

  function testAccess()
  {

  }

  function testSignTooLate() {

  }

  function testFadeoutToPool()
  {
    // also check if still the same options are calculated on termination
  }

  function prepExpectedOptionsAmount(uint count, ESOP E) returns (uint[])
  {
    // calculate option amount for 'count' employees
    uint[] memory options = new uint[](count);
    uint remPool = E.totalOptions();
    for(uint i=0; i<count; i++)
    {
      uint o = (remPool * E.newEmployeePoolPromille()) / 1000;
      options[i] = o;
      remPool -= o;
    }
    return options;
  }

  function massAddEmployees(uint count, ESOP E) returns (address[])
  {
    uint32 ct = esop.currentTime();
    address[] memory employees = new address[](count);
    for(uint i=0; i<count; i++) {
      emp1 = new EmpTester();
      employees[i] = emp1;
      E.addNewEmployeeToESOP(emp1, ct, ct + 2 weeks, 0);
      emp1._target(E);
    }
    return employees;
  }

  function checkOptionsInEmployeeList(EmployeesList employees, uint[] options)
  {
    Employee memory emp;
    uint j=0;
    uint size = employees.size();
    assertEq(size, options.length, "optcheck sizes must be equal");
    for(uint i=0; i< size; i++) {
      address ea = employees.addresses(i);
      if (ea != 0) { // address(0) is deleted employee
        var sere = employees.getSerializedEmployee(ea);
        assembly { emp := sere }
        //@info `uint emp.options` `uint options[j]`
        int diff = int(emp.options) - int(options[j]);
        if (diff > 1 || diff < -1)
          assertEq(uint(emp.options), options[j], "optcheck options");
        j++;
      }
    }
    //@info found `uint j` employees
  }

  function testSignaturesExpiredToPool()
  {
    ESOP E = new ESOP();
    address[] memory employees = massAddEmployees(15, E);
    uint[] memory options = prepExpectedOptionsAmount(15, E);
    // check pool before anything expires
    //@info `uint[] options`
    checkOptionsInEmployeeList(E.employees(), options);
    // now expire signatures
    uint32 ct = esop.currentTime();
    E.mockTime(ct+4 weeks);
    uint rc = uint(EmpTester(employees[7]).employeeSignsToESOP());
    // must return too late
    assertEq(rc, 2);
    checkOptionsInEmployeeList(E.employees(), options);
    rc = uint(EmpTester(employees[3]).employeeSignsToESOP());
    // must return too late
    assertEq(rc, 2);
    checkOptionsInEmployeeList(E.employees(), options);
    rc = uint(EmpTester(employees[14]).employeeSignsToESOP());
    // must return too late
    assertEq(rc, 2);
    checkOptionsInEmployeeList(E.employees(), options);
    // now return everyting in loop
    for(uint i=0; i<15; i++) {
      if(E.employees().hasEmployee(employees[i])) {
        rc = uint(EmpTester(employees[i]).employeeSignsToESOP());
        // must return too late
        assertEq(rc, 2);
        checkOptionsInEmployeeList(E.employees(), options);
      }
    }
    // all should be back in pool
    assertEq(E.totalOptions(), E.remainingOptions(), "all back in pool");
  }

  function testRemoveSignaturesExpiredToPool()
  {
    ESOP E = new ESOP();
    address[] memory employees = massAddEmployees(15, E);
    uint[] memory options = prepExpectedOptionsAmount(15, E);
    // check pool before anything expires
    //@info `uint[] options`
    checkOptionsInEmployeeList(E.employees(), options);
    // now expire signatures
    uint32 ct = esop.currentTime();
    E.mockTime(ct+4 weeks);
    E.removeEmployeesWithExpiredSignatures();
    // all should be back in pool
    assertEq(E.totalOptions(), E.remainingOptions(), "all back in pool");
  }

  function testLifecycleOptions()
  {

  }

  function testConversionStopsFadeout()
  {
    uint32 ct = esop.currentTime();
    esop.addNewEmployeeToESOP(emp1, ct, ct + 2 weeks, 100);
    emp1._target(esop);
    emp1.employeeSignsToESOP();
    // then after a year employee terminated regular
    ct += 1 years;
    rc = uint8(esop.terminateEmployee(emp1, ct, 0));
    assertEq(uint(rc), 0);
    // then after a month fund converts
    ct += 30 days;
    uint8 rc = uint8(esop.esopConversionEvent(ct, ct + 60 days, converter));
    assertEq(uint(rc), 0, "esopConversionEvent");
    uint optionsAtConv = esop.calcEffectiveOptionsForEmployee(address(emp1), ct);
    uint optionsCv1m = esop.calcEffectiveOptionsForEmployee(address(emp1), ct + 30 days);
    //@info options diff should be 0 `uint optionsAtConv` `uint optionsCv1m`
    assertEq(optionsCv1m, optionsAtConv);

  }

  function testEmployeeConversion() logs_gas()
  {
    uint32 ct = esop.currentTime();
    esop.addNewEmployeeToESOP(emp1, ct, ct + 2 weeks, 100);
    emp1._target(esop);
    ESOP(emp1).employeeSignsToESOP();
    // then after a year fund converts
    ct += 1 years;
    uint8 rc = uint8(esop.esopConversionEvent(ct, ct + 2 weeks, converter));
    assertEq(uint(rc), 0, "esopConversionEvent");
    // mock time
    uint32 toolate = (ct + 4 weeks);
    esop.mockTime(toolate);
    // should be too late
    //@info ct `uint32 ct` convertedAt `uint32 esop.conversionEventTime()` conv deadline `uint32 esop.employeeConversionDeadline()` too late `uint32 toolate`
    rc = emp1.employeeConvertsOptions();
    assertEq(uint(rc), 2, "employeeConvertsOptions");
    //@info `uint converter.totalConvertedOptions()` converted, should be 0
    esop.mockTime(ct + 2 weeks);
    // convert options
    rc = emp1.employeeConvertsOptions();
    assertEq(uint(rc), 0, "employeeConvertsOptions");
    // we expect all extra options + pool options + 20% exit bonus on pool options
    uint poolopts = esop.totalOptions() - esop.remainingOptions();
    uint expopts = 100 + poolopts + poolopts/5;
    // what is converted is stored in dummy so compare
    assertEq(converter.totalConvertedOptions(), expopts);
    //@info `uint expopts` converted
    // invalid emp state
    rc = emp1.employeeConvertsOptions();
    assertEq(uint(rc), 1, "employeeConvertsOptions");
    // 0 options left
    uint options = esop.calcEffectiveOptionsForEmployee(address(emp1), ct + 2 weeks);
    assertEq(options, 0);
  }

  function testEmployeeSimpleLifecycle() logs_gas()
  {
    uint32 ct = esop.currentTime();
    uint initialOptions = esop.remainingOptions();
    uint8 rc = uint8(esop.addNewEmployeeToESOP(emp1, ct, ct + 2 weeks, 100));
    assertEq(uint(rc), 0);
    emp1._target(esop);
    rc = emp1.employeeSignsToESOP();
    assertEq(uint(rc), 0);
    // terminated for a cause
    rc = uint8(esop.terminateEmployee(emp1, ct + 3 weeks, 2));
    assertEq(uint(rc), 0);
    assertEq(initialOptions, esop.remainingOptions());
  }

  function testMockTime() {
    //@info block number `uint block.number`
    uint32 t = esop.currentTime();
    assertEq(uint(t), block.timestamp);
    esop.mockTime(t + 4 weeks);
    assertEq(uint(esop.currentTime()), t + 4 weeks);
    // set back
    esop.mockTime(0);
    assertEq(uint(esop.currentTime()), block.timestamp);
  }
}